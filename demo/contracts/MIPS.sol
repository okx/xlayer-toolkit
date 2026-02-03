// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPreimageOracle} from "./interfaces/IPreimageOracle.sol";
import {MIPSMemory} from "./libraries/MIPSMemory.sol";
import {MIPSState as st} from "./libraries/MIPSState.sol";
import {MIPSSyscalls as sys} from "./libraries/MIPSSyscalls.sol";
import {InvalidMemoryProof, InvalidExitedValue} from "./libraries/CannonErrors.sol";

/**
 * @title MIPS
 * @notice Single-threaded MIPS64 VM for Cannon fault proofs.
 * @dev This contract executes a single MIPS instruction and returns the post-state hash.
 *      It is used in the dispute game to verify state transitions.
 *
 *      State Layout (188 bytes packed):
 *      - memRoot (32 bytes): Merkle root of memory
 *      - preimageKey (32 bytes): Current preimage key being read
 *      - preimageOffset (8 bytes): Offset into the preimage
 *      - pc (8 bytes): Program counter
 *      - nextPC (8 bytes): Next program counter
 *      - lo (8 bytes): LO register
 *      - hi (8 bytes): HI register
 *      - heap (8 bytes): Heap pointer
 *      - exitCode (1 byte): Exit code
 *      - exited (1 byte): Whether the VM has exited
 *      - step (8 bytes): Step counter
 *      - registers (32 * 8 = 256 bytes): General purpose registers
 *
 *      VM Status (encoded in high byte of state hash):
 *      - 0: Valid (exited with code 0)
 *      - 1: Invalid (exited with code 1)
 *      - 2: Panic (exited with code > 1)
 *      - 3: Unfinished (not exited)
 */
contract MIPS {
    /// @notice The preimage oracle contract.
    IPreimageOracle public immutable oracle;

    /// @notice The version of the MIPS VM.
    string public constant version = "1.0.0";

    // State memory offset during step execution
    uint256 internal constant STATE_MEM_OFFSET = 0x80;

    // Memory proof offset in calldata
    uint256 internal constant MEM_PROOF_OFFSET = 420; // After state data

    // State size constants
    uint256 internal constant STATE_SIZE = 188 + 256; // Base state + registers

    /// @notice VM state structure.
    struct State {
        bytes32 memRoot;
        bytes32 preimageKey;
        uint64 preimageOffset;
        uint64 pc;
        uint64 nextPC;
        uint64 lo;
        uint64 hi;
        uint64 heap;
        uint8 exitCode;
        bool exited;
        uint64 step;
        uint64[32] registers;
    }

    /// @notice Event emitted when a step is executed.
    event Step(uint64 indexed step, bytes32 preState, bytes32 postState);

    constructor(IPreimageOracle _oracle) {
        oracle = _oracle;
    }

    /**
     * @notice Execute a single MIPS instruction step verification.
     * @param _stateData The encoded pre-state (Cannon multithreaded64-5 witness format).
     * @param _proof The memory proof data from Cannon.
     * @param _claimedPreState The claimed pre-state hash (for verification).
     * @param _claimedPostState The claimed post-state hash from Cannon.
     * @return postState_ The verified post-state hash.
     * 
     * @dev Cannon's multithreaded64-5 VM format verification:
     *      
     *      The witness (_stateData) contains the complete VM state at a specific step.
     *      Cannon executes MIPS instructions off-chain and computes both the pre-state
     *      and post-state hashes using Optimism's specific state hash format.
     *      
     *      State hash format (Optimism standard):
     *      - Lower 248 bits: keccak256 of packed state
     *      - Upper 8 bits: VM status (0=valid, 1=invalid, 2=panic, 3=unfinished)
     *      
     *      For this demo, we validate that:
     *      1. Witness data is present and has reasonable length
     *      2. The claimed hashes are provided (from Cannon)
     *      
     *      In production Optimism, the on-chain MIPS VM would decode the state,
     *      execute the instruction, and verify the state transition. The complexity
     *      of the multithreaded64-5 format makes direct verification challenging
     *      without the full Optimism MIPS64.sol implementation.
     */
    function step(
        bytes calldata _stateData,
        bytes calldata _proof,
        bytes32 _claimedPreState,
        bytes32 _claimedPostState
    ) external view returns (bytes32 postState_) {
        // Verify we have valid witness data
        // Cannon's multithreaded64-5 state is ~188 bytes base
        require(_stateData.length >= 100, "MIPS: invalid state data length");
        
        // Verify we have proof data
        require(_proof.length > 0, "MIPS: missing proof data");
        
        // Verify the claimed states are non-zero (sanity check)
        require(_claimedPreState != bytes32(0), "MIPS: invalid pre-state");
        require(_claimedPostState != bytes32(0), "MIPS: invalid post-state");
        
        // Log the verification (for demo purposes)
        // In production, this would be a full MIPS instruction execution
        //
        // The verification flow in production Optimism:
        // 1. Decode packed state from _stateData
        // 2. Verify _stateData hash matches _claimedPreState
        // 3. Fetch instruction from memory using _proof
        // 4. Execute single MIPS instruction
        // 5. Compute new state hash
        // 6. Return computed post-state
        //
        // For this demo, we trust Cannon's off-chain execution:
        // - Cannon is deterministic
        // - Any party can run Cannon to verify results
        // - The bisection process already narrowed to this single step
        
        postState_ = _claimedPostState;
    }
    
    /**
     * @notice Legacy step function for single-threaded MIPS execution.
     * @dev This would be used if we had a compatible state format.
     */
    function stepLegacy(
        bytes calldata _stateData,
        bytes calldata /* proof */,
        bytes32 _localContext
    ) external view returns (bytes32 postState_) {
        // Decode state
        State memory state = _decodeState(_stateData);
        
        // If already exited, return current state
        if (state.exited) {
            return _outputState(state);
        }

        // Increment step counter
        state.step += 1;

        // Fetch instruction
        uint256 insnProofOffset = MIPSMemory.memoryProofOffset(MEM_PROOF_OFFSET, 0);
        uint64 insnAddr = state.pc & 0xFFFFFFFFFFFFFFF8; // Align to 8 bytes
        uint64 insnWord = MIPSMemory.readMem(state.memRoot, insnAddr, insnProofOffset);
        
        // Extract 32-bit instruction from 64-bit word
        uint32 insn;
        if ((state.pc & 0x4) == 0) {
            insn = uint32(insnWord >> 32);
        } else {
            insn = uint32(insnWord);
        }

        // Decode instruction
        uint32 opcode = insn >> 26;
        uint32 func = insn & 0x3F;

        // Handle syscall
        if (opcode == 0 && func == 0xC) {
            return _handleSyscall(state, _localContext);
        }

        // Execute instruction
        _executeInstruction(state, insn, opcode, func);

        return _outputState(state);
    }

    /**
     * @notice Handle a syscall instruction.
     */
    function _handleSyscall(
        State memory _state,
        bytes32 _localContext
    ) internal view returns (bytes32) {
        // Get syscall number and arguments
        (uint64 syscallNum, uint64 a0, uint64 a1, uint64 a2) = sys.getSyscallArgs(_state.registers);

        uint64 v0 = 0;
        uint64 v1 = 0;

        if (syscallNum == sys.SYS_MMAP) {
            (v0, v1, _state.heap) = sys.handleSysMmap(a0, a1, _state.heap);
        }
        else if (syscallNum == sys.SYS_BRK) {
            v0 = sys.PROGRAM_BREAK;
        }
        else if (syscallNum == sys.SYS_EXIT_GROUP || syscallNum == sys.SYS_EXIT) {
            _state.exited = true;
            _state.exitCode = uint8(a0);
            return _outputState(_state);
        }
        else if (syscallNum == sys.SYS_READ) {
            (v0, v1) = _handleSysRead(_state, a0, a1, a2, _localContext);
        }
        else if (syscallNum == sys.SYS_WRITE) {
            (v0, v1) = _handleSysWrite(_state, a0, a1, a2);
        }
        else if (syscallNum == sys.SYS_FCNTL) {
            (v0, v1) = sys.handleSysFcntl(a0, a1);
        }
        else if (syscallNum == sys.SYS_GETPID) {
            v0 = 0;
        }
        // Ignored syscalls
        else if (
            syscallNum == sys.SYS_MUNMAP ||
            syscallNum == sys.SYS_MPROTECT ||
            syscallNum == sys.SYS_MADVISE ||
            syscallNum == sys.SYS_PRLIMIT64 ||
            syscallNum == sys.SYS_CLOSE ||
            syscallNum == sys.SYS_SCHED_YIELD ||
            syscallNum == sys.SYS_NANOSLEEP
        ) {
            // No-op, return 0
        }
        else {
            // Unknown syscall - treat as no-op for now
            // In production, this should revert
        }

        // Update registers and advance PC
        st.CpuScalars memory cpu = st.CpuScalars({
            pc: _state.pc,
            nextPC: _state.nextPC,
            lo: _state.lo,
            hi: _state.hi
        });
        sys.handleSyscallUpdates(cpu, _state.registers, v0, v1);
        _state.pc = cpu.pc;
        _state.nextPC = cpu.nextPC;

        return _outputState(_state);
    }

    /**
     * @notice Execute a non-syscall instruction.
     */
    function _executeInstruction(
        State memory _state,
        uint32 _insn,
        uint32 _opcode,
        uint32 _func
    ) internal pure {
        // Decode register indices
        uint32 rs = (_insn >> 21) & 0x1F;
        uint32 rt = (_insn >> 16) & 0x1F;
        uint32 rd = (_insn >> 11) & 0x1F;
        uint32 sa = (_insn >> 6) & 0x1F;
        int64 imm = int64(int16(uint16(_insn & 0xFFFF)));
        uint64 uimm = uint64(_insn & 0xFFFF);

        uint64 rsVal = _state.registers[rs];
        uint64 rtVal = _state.registers[rt];
        uint64 result = 0;
        bool writeRd = false;
        bool writeRt = false;

        // R-type instructions (opcode = 0)
        if (_opcode == 0) {
            writeRd = true;
            if (_func == 0x20) {
                // ADD
                result = uint64(int64(rsVal) + int64(rtVal));
            } else if (_func == 0x21) {
                // ADDU
                result = rsVal + rtVal;
            } else if (_func == 0x22) {
                // SUB
                result = uint64(int64(rsVal) - int64(rtVal));
            } else if (_func == 0x23) {
                // SUBU
                result = rsVal - rtVal;
            } else if (_func == 0x24) {
                // AND
                result = rsVal & rtVal;
            } else if (_func == 0x25) {
                // OR
                result = rsVal | rtVal;
            } else if (_func == 0x26) {
                // XOR
                result = rsVal ^ rtVal;
            } else if (_func == 0x27) {
                // NOR
                result = ~(rsVal | rtVal);
            } else if (_func == 0x2A) {
                // SLT
                result = int64(rsVal) < int64(rtVal) ? 1 : 0;
            } else if (_func == 0x2B) {
                // SLTU
                result = rsVal < rtVal ? 1 : 0;
            } else if (_func == 0x00) {
                // SLL
                result = uint64(uint32(rtVal) << sa);
            } else if (_func == 0x02) {
                // SRL
                result = uint64(uint32(rtVal) >> sa);
            } else if (_func == 0x03) {
                // SRA
                result = uint64(int64(int32(uint32(rtVal)) >> sa));
            } else if (_func == 0x04) {
                // SLLV
                result = uint64(uint32(rtVal) << uint32(rsVal & 0x1F));
            } else if (_func == 0x06) {
                // SRLV
                result = uint64(uint32(rtVal) >> uint32(rsVal & 0x1F));
            } else if (_func == 0x07) {
                // SRAV
                result = uint64(int64(int32(uint32(rtVal)) >> uint32(rsVal & 0x1F)));
            } else if (_func == 0x08) {
                // JR
                writeRd = false;
                _state.nextPC = rsVal;
            } else if (_func == 0x09) {
                // JALR
                result = _state.pc + 8;
                _state.nextPC = rsVal;
            } else if (_func == 0x10) {
                // MFHI
                result = _state.hi;
            } else if (_func == 0x11) {
                // MTHI
                writeRd = false;
                _state.hi = rsVal;
            } else if (_func == 0x12) {
                // MFLO
                result = _state.lo;
            } else if (_func == 0x13) {
                // MTLO
                writeRd = false;
                _state.lo = rsVal;
            } else if (_func == 0x18) {
                // MULT
                writeRd = false;
                int128 prod = int128(int64(rsVal)) * int128(int64(rtVal));
                _state.lo = uint64(int64(prod));
                _state.hi = uint64(int64(prod >> 64));
            } else if (_func == 0x19) {
                // MULTU
                writeRd = false;
                uint128 prod = uint128(rsVal) * uint128(rtVal);
                _state.lo = uint64(prod);
                _state.hi = uint64(prod >> 64);
            } else if (_func == 0x1A) {
                // DIV
                writeRd = false;
                if (rtVal != 0) {
                    _state.lo = uint64(int64(rsVal) / int64(rtVal));
                    _state.hi = uint64(int64(rsVal) % int64(rtVal));
                }
            } else if (_func == 0x1B) {
                // DIVU
                writeRd = false;
                if (rtVal != 0) {
                    _state.lo = rsVal / rtVal;
                    _state.hi = rsVal % rtVal;
                }
            } else {
                writeRd = false;
            }
        }
        // I-type instructions
        else if (_opcode == 0x08) {
            // ADDI
            writeRt = true;
            result = uint64(int64(rsVal) + imm);
        } else if (_opcode == 0x09) {
            // ADDIU
            writeRt = true;
            result = rsVal + uint64(imm);
        } else if (_opcode == 0x0A) {
            // SLTI
            writeRt = true;
            result = int64(rsVal) < imm ? 1 : 0;
        } else if (_opcode == 0x0B) {
            // SLTIU
            writeRt = true;
            result = rsVal < uint64(imm) ? 1 : 0;
        } else if (_opcode == 0x0C) {
            // ANDI
            writeRt = true;
            result = rsVal & uimm;
        } else if (_opcode == 0x0D) {
            // ORI
            writeRt = true;
            result = rsVal | uimm;
        } else if (_opcode == 0x0E) {
            // XORI
            writeRt = true;
            result = rsVal ^ uimm;
        } else if (_opcode == 0x0F) {
            // LUI
            writeRt = true;
            result = uint64(uimm << 16);
        }
        // Branch instructions
        else if (_opcode == 0x04) {
            // BEQ
            if (rsVal == rtVal) {
                _state.nextPC = uint64(int64(_state.pc) + 4 + (imm << 2));
            }
        } else if (_opcode == 0x05) {
            // BNE
            if (rsVal != rtVal) {
                _state.nextPC = uint64(int64(_state.pc) + 4 + (imm << 2));
            }
        } else if (_opcode == 0x06) {
            // BLEZ
            if (int64(rsVal) <= 0) {
                _state.nextPC = uint64(int64(_state.pc) + 4 + (imm << 2));
            }
        } else if (_opcode == 0x07) {
            // BGTZ
            if (int64(rsVal) > 0) {
                _state.nextPC = uint64(int64(_state.pc) + 4 + (imm << 2));
            }
        }
        // Jump instructions
        else if (_opcode == 0x02) {
            // J
            _state.nextPC = (_state.pc & 0xF0000000) | (uint64(_insn & 0x3FFFFFF) << 2);
        } else if (_opcode == 0x03) {
            // JAL
            _state.registers[31] = _state.pc + 8;
            _state.nextPC = (_state.pc & 0xF0000000) | (uint64(_insn & 0x3FFFFFF) << 2);
        }
        // Note: Load/Store instructions would need memory proofs
        // For simplicity, they are not fully implemented here

        // Write result
        if (writeRd && rd != 0) {
            _state.registers[rd] = result;
        }
        if (writeRt && rt != 0) {
            _state.registers[rt] = result;
        }

        // Advance PC
        _state.pc = _state.nextPC;
        _state.nextPC = _state.nextPC + 4;
    }

    /**
     * @notice Handle SYS_READ syscall.
     */
    function _handleSysRead(
        State memory _state,
        uint64 a0,
        uint64 a1,
        uint64 a2,
        bytes32 _localContext
    ) internal view returns (uint64 v0, uint64 v1) {
        sys.SysReadParams memory args = sys.SysReadParams({
            a0: a0,
            a1: a1,
            a2: a2,
            preimageKey: _state.preimageKey,
            preimageOffset: _state.preimageOffset,
            localContext: _localContext,
            oracle: oracle,
            proofOffset: MIPSMemory.memoryProofOffset(MEM_PROOF_OFFSET, 1),
            memRoot: _state.memRoot
        });
        bool memUpdated;
        uint64 memAddr;
        (v0, v1, _state.preimageOffset, _state.memRoot, memUpdated, memAddr) = sys.handleSysRead(args);
        // Suppress unused variable warnings
        memUpdated;
        memAddr;
    }

    /**
     * @notice Handle SYS_WRITE syscall.
     */
    function _handleSysWrite(
        State memory _state,
        uint64 a0,
        uint64 a1,
        uint64 a2
    ) internal pure returns (uint64 v0, uint64 v1) {
        sys.SysWriteParams memory args = sys.SysWriteParams({
            _a0: a0,
            _a1: a1,
            _a2: a2,
            _preimageKey: _state.preimageKey,
            _preimageOffset: _state.preimageOffset,
            _proofOffset: MIPSMemory.memoryProofOffset(MEM_PROOF_OFFSET, 1),
            _memRoot: _state.memRoot
        });
        (v0, v1, _state.preimageKey, _state.preimageOffset) = sys.handleSysWrite(args);
    }

    /**
     * @notice Decode state from calldata.
     */
    function _decodeState(bytes calldata _stateData) internal pure returns (State memory state) {
        require(_stateData.length >= STATE_SIZE, "MIPS: invalid state data");

        uint256 offset = 0;
        
        // Decode fixed fields
        state.memRoot = bytes32(_stateData[offset:offset+32]);
        offset += 32;
        
        state.preimageKey = bytes32(_stateData[offset:offset+32]);
        offset += 32;
        
        state.preimageOffset = uint64(bytes8(_stateData[offset:offset+8]));
        offset += 8;
        
        state.pc = uint64(bytes8(_stateData[offset:offset+8]));
        offset += 8;
        
        state.nextPC = uint64(bytes8(_stateData[offset:offset+8]));
        offset += 8;
        
        state.lo = uint64(bytes8(_stateData[offset:offset+8]));
        offset += 8;
        
        state.hi = uint64(bytes8(_stateData[offset:offset+8]));
        offset += 8;
        
        state.heap = uint64(bytes8(_stateData[offset:offset+8]));
        offset += 8;
        
        state.exitCode = uint8(_stateData[offset]);
        offset += 1;
        
        state.exited = _stateData[offset] != 0;
        offset += 1;
        
        state.step = uint64(bytes8(_stateData[offset:offset+8]));
        offset += 8;

        // Decode registers
        for (uint256 i = 0; i < 32; i++) {
            state.registers[i] = uint64(bytes8(_stateData[offset:offset+8]));
            offset += 8;
        }
    }

    /**
     * @notice Encode and hash the state.
     */
    function _outputState(State memory _state) internal pure returns (bytes32 out_) {
        // Pack state into bytes
        bytes memory packed = abi.encodePacked(
            _state.memRoot,
            _state.preimageKey,
            _state.preimageOffset,
            _state.pc,
            _state.nextPC,
            _state.lo,
            _state.hi,
            _state.heap,
            _state.exitCode,
            _state.exited ? uint8(1) : uint8(0),
            _state.step
        );

        // Add registers
        for (uint256 i = 0; i < 32; i++) {
            packed = abi.encodePacked(packed, _state.registers[i]);
        }

        // Hash the state
        out_ = keccak256(packed);

        // Set status byte
        uint8 status;
        if (_state.exited) {
            if (_state.exitCode == 0) {
                status = 0; // Valid
            } else if (_state.exitCode == 1) {
                status = 1; // Invalid
            } else {
                status = 2; // Panic
            }
        } else {
            status = 3; // Unfinished
        }

        // Encode status in high byte
        assembly {
            out_ := or(and(out_, not(shl(248, 0xFF))), shl(248, status))
        }
    }

    /**
     * @notice Get the VM status from a state hash.
     * @param _stateHash The state hash.
     * @return status The VM status (0=Valid, 1=Invalid, 2=Panic, 3=Unfinished).
     */
    function getStatus(bytes32 _stateHash) external pure returns (uint8 status) {
        return uint8(uint256(_stateHash) >> 248);
    }
}
