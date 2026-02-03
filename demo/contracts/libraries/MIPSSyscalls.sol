// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MIPSMemory} from "./MIPSMemory.sol";
import {MIPSState as st} from "./MIPSState.sol";
import {IPreimageOracle} from "../interfaces/IPreimageOracle.sol";
import {PreimageKeyLib} from "./PreimageKeyLib.sol";

/**
 * @title MIPSSyscalls
 * @notice Library for handling MIPS system calls in the Cannon VM.
 * @dev Implements Linux MIPS64 syscall interface for:
 *      - Memory management (mmap, brk)
 *      - File I/O (read, write, fcntl)
 *      - Process control (exit, exit_group)
 *      - Preimage oracle access
 */
library MIPSSyscalls {
    // =========================================================================
    // Syscall Parameters Structs
    // =========================================================================

    struct SysReadParams {
        uint64 a0;              // File descriptor
        uint64 a1;              // Memory address to read to
        uint64 a2;              // Number of bytes to read
        bytes32 preimageKey;    // Current preimage key
        uint64 preimageOffset;  // Current preimage offset
        bytes32 localContext;   // Local context for preimage key
        IPreimageOracle oracle; // Preimage oracle contract
        uint256 proofOffset;    // Memory proof offset in calldata
        bytes32 memRoot;        // Current memory root
    }

    struct SysWriteParams {
        uint64 _a0;             // File descriptor
        uint64 _a1;             // Memory address to read from
        uint64 _a2;             // Number of bytes to write
        bytes32 _preimageKey;   // Current preimage key
        uint64 _preimageOffset; // Current preimage offset
        uint256 _proofOffset;   // Memory proof offset in calldata
        bytes32 _memRoot;       // Current memory root
    }

    // =========================================================================
    // Constants
    // =========================================================================

    uint64 internal constant U64_MASK = 0xFFffFFffFFffFFff;
    uint64 internal constant PAGE_ADDR_MASK = 4095;
    uint64 internal constant PAGE_SIZE = 4096;
    uint64 internal constant WORD_SIZE_BYTES = 8;
    uint64 internal constant EXT_MASK = 0x7;
    uint64 internal constant ADDRESS_MASK = 0xFFFFFFFFFFFFFFF8;

    // Syscall numbers (MIPS64 Linux)
    uint32 internal constant SYS_READ = 5000;
    uint32 internal constant SYS_WRITE = 5001;
    uint32 internal constant SYS_OPEN = 5002;
    uint32 internal constant SYS_CLOSE = 5003;
    uint32 internal constant SYS_MMAP = 5009;
    uint32 internal constant SYS_BRK = 5012;
    uint32 internal constant SYS_EXIT = 5058;
    uint32 internal constant SYS_FCNTL = 5070;
    uint32 internal constant SYS_EXIT_GROUP = 5205;
    uint32 internal constant SYS_CLONE = 5055;
    uint32 internal constant SYS_SCHED_YIELD = 5023;
    uint32 internal constant SYS_GETTID = 5178;
    uint32 internal constant SYS_FUTEX = 5194;
    uint32 internal constant SYS_NANOSLEEP = 5034;
    uint32 internal constant SYS_CLOCKGETTIME = 5222;
    uint32 internal constant SYS_GETPID = 5038;
    
    // No-op syscalls
    uint32 internal constant SYS_MUNMAP = 5011;
    uint32 internal constant SYS_MPROTECT = 5010;
    uint32 internal constant SYS_MADVISE = 5027;
    uint32 internal constant SYS_PRLIMIT64 = 5297;

    // File descriptors
    uint32 internal constant FD_STDIN = 0;
    uint32 internal constant FD_STDOUT = 1;
    uint32 internal constant FD_STDERR = 2;
    uint32 internal constant FD_HINT_READ = 3;
    uint32 internal constant FD_HINT_WRITE = 4;
    uint32 internal constant FD_PREIMAGE_READ = 5;
    uint32 internal constant FD_PREIMAGE_WRITE = 6;

    // Error codes
    uint64 internal constant SYS_ERROR_SIGNAL = U64_MASK;
    uint64 internal constant EBADF = 0x9;
    uint64 internal constant EINVAL = 0x16;
    uint64 internal constant EAGAIN = 0xb;

    // Memory limits
    uint64 internal constant PROGRAM_BREAK = 0x00_00_40_00_00_00_00_00;
    uint64 internal constant HEAP_END = 0x00_00_60_00_00_00_00_00;

    // Scheduler quantum
    uint64 internal constant SCHED_QUANTUM = 100_000;
    uint64 internal constant HZ = 10_000_000;
    uint64 internal constant CLOCK_GETTIME_REALTIME_FLAG = 0;
    uint64 internal constant CLOCK_GETTIME_MONOTONIC_FLAG = 1;

    // Clone flags
    uint64 internal constant CLONE_VM = 0x100;
    uint64 internal constant CLONE_FS = 0x200;
    uint64 internal constant CLONE_FILES = 0x400;
    uint64 internal constant CLONE_SIGHAND = 0x800;
    uint64 internal constant CLONE_SYSVSEM = 0x40000;
    uint64 internal constant CLONE_THREAD = 0x10000;
    uint64 internal constant VALID_SYS_CLONE_FLAGS =
        CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_SYSVSEM | CLONE_THREAD;

    // Futex operations
    uint64 internal constant FUTEX_WAIT_PRIVATE = 128;
    uint64 internal constant FUTEX_WAKE_PRIVATE = 129;

    // Register indices
    uint32 internal constant REG_V0 = 2;
    uint32 internal constant REG_A0 = 4;
    uint32 internal constant REG_A1 = 5;
    uint32 internal constant REG_A2 = 6;
    uint32 internal constant REG_A3 = 7;

    uint32 internal constant REG_SYSCALL_NUM = REG_V0;
    uint32 internal constant REG_SYSCALL_ERRNO = REG_A3;
    uint32 internal constant REG_SYSCALL_RET1 = REG_V0;
    uint32 internal constant REG_SYSCALL_PARAM1 = REG_A0;
    uint32 internal constant REG_SYSCALL_PARAM2 = REG_A1;
    uint32 internal constant REG_SYSCALL_PARAM3 = REG_A2;

    // =========================================================================
    // Syscall Argument Extraction
    // =========================================================================

    /**
     * @notice Extract syscall number and arguments from registers.
     * @param _registers The CPU registers.
     * @return sysCallNum_ The syscall number.
     * @return a0_ First argument.
     * @return a1_ Second argument.
     * @return a2_ Third argument.
     */
    function getSyscallArgs(uint64[32] memory _registers)
        internal
        pure
        returns (uint64 sysCallNum_, uint64 a0_, uint64 a1_, uint64 a2_)
    {
        unchecked {
            sysCallNum_ = _registers[REG_SYSCALL_NUM];
            a0_ = _registers[REG_SYSCALL_PARAM1];
            a1_ = _registers[REG_SYSCALL_PARAM2];
            a2_ = _registers[REG_SYSCALL_PARAM3];
            return (sysCallNum_, a0_, a1_, a2_);
        }
    }

    // =========================================================================
    // Syscall Handlers
    // =========================================================================

    /**
     * @notice Handle mmap syscall.
     * @param _a0 The requested address (0 for any).
     * @param _a1 The size of the mapping.
     * @param _heap The current heap pointer.
     * @return v0_ The address of the mapping or error code.
     * @return v1_ Error signal (0 on success).
     * @return newHeap_ The new heap pointer.
     */
    function handleSysMmap(
        uint64 _a0,
        uint64 _a1,
        uint64 _heap
    ) internal pure returns (uint64 v0_, uint64 v1_, uint64 newHeap_) {
        unchecked {
            v1_ = uint64(0);
            newHeap_ = _heap;

            uint64 sz = _a1;
            if (sz & PAGE_ADDR_MASK != 0) {
                // Align size to page boundary
                sz += PAGE_SIZE - (sz & PAGE_ADDR_MASK);
            }
            if (_a0 == 0) {
                v0_ = _heap;
                newHeap_ += sz;
                // Check for overflow or exceeding heap limit
                if (newHeap_ > HEAP_END || newHeap_ < _heap || sz < _a1) {
                    v0_ = EINVAL;
                    v1_ = SYS_ERROR_SIGNAL;
                    return (v0_, v1_, _heap);
                }
            } else {
                v0_ = _a0;
            }

            return (v0_, v1_, newHeap_);
        }
    }

    /**
     * @notice Handle read syscall.
     * @param _args The syscall parameters.
     * @return v0_ Number of bytes read or error code.
     * @return v1_ Error signal (0 on success).
     * @return newPreimageOffset_ Updated preimage offset.
     * @return newMemRoot_ Updated memory root.
     * @return memUpdated_ Whether memory was updated.
     * @return memAddr_ The address that was updated.
     */
    function handleSysRead(SysReadParams memory _args)
        internal
        view
        returns (
            uint64 v0_,
            uint64 v1_,
            uint64 newPreimageOffset_,
            bytes32 newMemRoot_,
            bool memUpdated_,
            uint64 memAddr_
        )
    {
        unchecked {
            v0_ = uint64(0);
            v1_ = uint64(0);
            newMemRoot_ = _args.memRoot;
            newPreimageOffset_ = _args.preimageOffset;
            memUpdated_ = false;
            memAddr_ = 0;

            if (_args.a0 == FD_STDIN) {
                // Read nothing from stdin
            }
            else if (_args.a0 == FD_PREIMAGE_READ) {
                uint64 effAddr = _args.a1 & ADDRESS_MASK;
                // Read existing memory
                uint64 mem = MIPSMemory.readMem(_args.memRoot, effAddr, _args.proofOffset);
                
                // Localize key if needed
                bytes32 preimageKey = _args.preimageKey;
                if (uint8(preimageKey[0]) == 1) {
                    preimageKey = PreimageKeyLib.localizeIdent(
                        uint256(preimageKey) & ((1 << 248) - 1),
                        _args.localContext
                    );
                }
                
                // Read from oracle
                (bytes32 dat, uint256 datLen) = _args.oracle.readPreimage(preimageKey, _args.preimageOffset);

                // Transform data for writing to memory
                uint64 a1 = _args.a1;
                uint64 a2 = _args.a2;
                assembly {
                    let alignment := and(a1, EXT_MASK)
                    let space := sub(WORD_SIZE_BYTES, alignment)
                    if lt(space, datLen) { datLen := space }
                    if lt(a2, datLen) { datLen := a2 }
                    dat := shr(sub(256, mul(datLen, 8)), dat)
                    dat := shl(mul(sub(sub(WORD_SIZE_BYTES, datLen), alignment), 8), dat)
                    let mask := sub(shl(mul(sub(WORD_SIZE_BYTES, alignment), 8), 1), 1)
                    let suffixMask := sub(shl(mul(sub(sub(WORD_SIZE_BYTES, alignment), datLen), 8), 1), 1)
                    mask := and(mask, not(suffixMask))
                    mem := or(and(mem, not(mask)), dat)
                }

                // Write memory back
                newMemRoot_ = MIPSMemory.writeMem(effAddr, _args.proofOffset, mem);
                memUpdated_ = true;
                memAddr_ = effAddr;
                newPreimageOffset_ += uint64(datLen);
                v0_ = uint64(datLen);
            }
            else if (_args.a0 == FD_HINT_READ) {
                // Pretend we read everything
                v0_ = _args.a2;
            }
            else {
                v0_ = EBADF;
                v1_ = SYS_ERROR_SIGNAL;
            }

            return (v0_, v1_, newPreimageOffset_, newMemRoot_, memUpdated_, memAddr_);
        }
    }

    /**
     * @notice Handle write syscall.
     * @param _args The syscall parameters.
     * @return v0_ Number of bytes written or error code.
     * @return v1_ Error signal (0 on success).
     * @return newPreimageKey_ Updated preimage key.
     * @return newPreimageOffset_ Updated preimage offset.
     */
    function handleSysWrite(SysWriteParams memory _args)
        internal
        pure
        returns (uint64 v0_, uint64 v1_, bytes32 newPreimageKey_, uint64 newPreimageOffset_)
    {
        unchecked {
            v0_ = uint64(0);
            v1_ = uint64(0);
            newPreimageKey_ = _args._preimageKey;
            newPreimageOffset_ = _args._preimageOffset;

            if (_args._a0 == FD_STDOUT || _args._a0 == FD_STDERR || _args._a0 == FD_HINT_WRITE) {
                v0_ = _args._a2; // Pretend we wrote everything
            }
            else if (_args._a0 == FD_PREIMAGE_WRITE) {
                // Read memory to construct preimage key
                uint64 mem = MIPSMemory.readMem(_args._memRoot, _args._a1 & ADDRESS_MASK, _args._proofOffset);
                bytes32 key = _args._preimageKey;

                uint64 _a1 = _args._a1;
                uint64 _a2 = _args._a2;
                assembly {
                    let alignment := and(_a1, EXT_MASK)
                    let space := sub(WORD_SIZE_BYTES, alignment)
                    if lt(space, _a2) { _a2 := space }
                    key := shl(mul(_a2, 8), key)
                    let mask := sub(shl(mul(_a2, 8), 1), 1)
                    mem := and(shr(mul(sub(space, _a2), 8), mem), mask)
                    key := or(key, mem)
                }
                _args._a2 = _a2;

                newPreimageKey_ = key;
                newPreimageOffset_ = 0; // Reset offset for new preimage
                v0_ = _args._a2;
            }
            else {
                v0_ = EBADF;
                v1_ = SYS_ERROR_SIGNAL;
            }

            return (v0_, v1_, newPreimageKey_, newPreimageOffset_);
        }
    }

    /**
     * @notice Handle fcntl syscall.
     * @param _a0 File descriptor.
     * @param _a1 Command.
     * @return v0_ Result or error code.
     * @return v1_ Error signal (0 on success).
     */
    function handleSysFcntl(uint64 _a0, uint64 _a1) internal pure returns (uint64 v0_, uint64 v1_) {
        unchecked {
            v0_ = uint64(0);
            v1_ = uint64(0);

            if (_a1 == 1) {
                // F_GETFD: get file descriptor flags
                if (
                    _a0 == FD_STDIN || _a0 == FD_STDOUT || _a0 == FD_STDERR ||
                    _a0 == FD_PREIMAGE_READ || _a0 == FD_HINT_READ ||
                    _a0 == FD_PREIMAGE_WRITE || _a0 == FD_HINT_WRITE
                ) {
                    v0_ = 0;
                } else {
                    v0_ = EBADF;
                    v1_ = SYS_ERROR_SIGNAL;
                }
            } else if (_a1 == 3) {
                // F_GETFL: get file status flags
                if (_a0 == FD_STDIN || _a0 == FD_PREIMAGE_READ || _a0 == FD_HINT_READ) {
                    v0_ = 0; // O_RDONLY
                } else if (_a0 == FD_STDOUT || _a0 == FD_STDERR || _a0 == FD_PREIMAGE_WRITE || _a0 == FD_HINT_WRITE) {
                    v0_ = 1; // O_WRONLY
                } else {
                    v0_ = EBADF;
                    v1_ = SYS_ERROR_SIGNAL;
                }
            } else {
                v0_ = EINVAL;
                v1_ = SYS_ERROR_SIGNAL;
            }

            return (v0_, v1_);
        }
    }

    /**
     * @notice Update registers and PC after syscall.
     * @param _cpu CPU state.
     * @param _registers Register file.
     * @param _v0 Return value.
     * @param _v1 Error signal.
     */
    function handleSyscallUpdates(
        st.CpuScalars memory _cpu,
        uint64[32] memory _registers,
        uint64 _v0,
        uint64 _v1
    ) internal pure {
        unchecked {
            _registers[REG_SYSCALL_RET1] = _v0;
            _registers[REG_SYSCALL_ERRNO] = _v1;
            _cpu.pc = _cpu.nextPC;
            _cpu.nextPC = _cpu.nextPC + 4;
        }
    }
}
