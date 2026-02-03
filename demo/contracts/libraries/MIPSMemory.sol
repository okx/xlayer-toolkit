// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {InvalidMemoryProof} from "./CannonErrors.sol";

/**
 * @title MIPSMemory
 * @notice Library for MIPS memory operations with Merkle proof verification.
 * @dev Uses a 64-bit address space with 32-byte leaf values.
 *      Memory proofs are 60 * 32 = 1920 bytes (59 siblings + 1 leaf).
 */
library MIPSMemory {
    /// @notice Mask for 8-byte alignment
    uint64 internal constant EXT_MASK = 0x7;
    
    /// @notice Number of 32-byte entries in a memory proof
    uint64 internal constant MEM_PROOF_LEAF_COUNT = 60;
    
    /// @notice Mask for 64-bit values
    uint256 internal constant U64_MASK = 0xFFFFFFFFFFFFFFFF;

    /**
     * @notice Read a 64-bit word from memory with proof verification.
     * @param _memRoot The current memory Merkle root.
     * @param _addr The address to read from (must be 8-byte aligned).
     * @param _proofOffset The offset of the memory proof in calldata.
     * @return out_ The 64-bit value at the address.
     */
    function readMem(
        bytes32 _memRoot,
        uint64 _addr,
        uint256 _proofOffset
    ) internal pure returns (uint64 out_) {
        bool valid;
        (out_, valid) = readMemUnchecked(_memRoot, _addr, _proofOffset);
        if (!valid) {
            revert InvalidMemoryProof();
        }
    }

    /**
     * @notice Read a 64-bit word from memory without reverting on invalid proof.
     * @param _memRoot The current memory Merkle root.
     * @param _addr The address to read from (must be 8-byte aligned).
     * @param _proofOffset The offset of the memory proof in calldata.
     * @return out_ The 64-bit value at the address.
     * @return valid_ Whether the proof is valid.
     */
    function readMemUnchecked(
        bytes32 _memRoot,
        uint64 _addr,
        uint256 _proofOffset
    ) internal pure returns (uint64 out_, bool valid_) {
        unchecked {
            validateMemoryProofAvailability(_proofOffset);
            assembly {
                // Validate the address alignment.
                if and(_addr, EXT_MASK) {
                    // revert InvalidAddress();
                    let ptr := mload(0x40)
                    mstore(ptr, shl(224, 0xe6c4247b))
                    revert(ptr, 0x4)
                }

                // Load the leaf value.
                let leaf := calldataload(_proofOffset)
                _proofOffset := add(_proofOffset, 32)

                // Convenience function to hash two nodes together in scratch space.
                function hashPair(a, b) -> h {
                    mstore(0, a)
                    mstore(32, b)
                    h := keccak256(0, 64)
                }

                // Start with the leaf node.
                // Work back up by combining with siblings, to reconstruct the root.
                let path := shr(5, _addr)
                let node := leaf
                let end := sub(MEM_PROOF_LEAF_COUNT, 1)
                for { let i := 0 } lt(i, end) { i := add(i, 1) } {
                    let sibling := calldataload(_proofOffset)
                    _proofOffset := add(_proofOffset, 32)
                    switch and(shr(i, path), 1)
                    case 0 { node := hashPair(node, sibling) }
                    case 1 { node := hashPair(sibling, node) }
                }

                // Verify the root matches.
                valid_ := eq(node, _memRoot)
                if valid_ {
                    // Bits to shift = (32 - 8 - (addr % 32)) * 8
                    let shamt := shl(3, sub(sub(32, 8), and(_addr, 31)))
                    out_ := and(shr(shamt, leaf), U64_MASK)
                }
            }
        }
    }

    /**
     * @notice Write a 64-bit word to memory and return the new Merkle root.
     * @param _addr The address to write to (must be 8-byte aligned).
     * @param _proofOffset The offset of the memory proof in calldata.
     * @param _val The 64-bit value to write.
     * @return newMemRoot_ The new memory Merkle root.
     */
    function writeMem(
        uint64 _addr,
        uint256 _proofOffset,
        uint64 _val
    ) internal pure returns (bytes32 newMemRoot_) {
        unchecked {
            validateMemoryProofAvailability(_proofOffset);
            assembly {
                // Validate the address alignment.
                if and(_addr, EXT_MASK) {
                    // revert InvalidAddress();
                    let ptr := mload(0x40)
                    mstore(ptr, shl(224, 0xe6c4247b))
                    revert(ptr, 0x4)
                }

                // Load the leaf value.
                let leaf := calldataload(_proofOffset)
                let shamt := shl(3, sub(sub(32, 8), and(_addr, 31)))

                // Mask out 8 bytes, and OR in the value
                leaf := or(and(leaf, not(shl(shamt, U64_MASK))), shl(shamt, _val))
                _proofOffset := add(_proofOffset, 32)

                // Convenience function to hash two nodes together in scratch space.
                function hashPair(a, b) -> h {
                    mstore(0, a)
                    mstore(32, b)
                    h := keccak256(0, 64)
                }

                // Start with the leaf node.
                // Work back up by combining with siblings, to reconstruct the root.
                let path := shr(5, _addr)
                let node := leaf
                let end := sub(MEM_PROOF_LEAF_COUNT, 1)
                for { let i := 0 } lt(i, end) { i := add(i, 1) } {
                    let sibling := calldataload(_proofOffset)
                    _proofOffset := add(_proofOffset, 32)
                    switch and(shr(i, path), 1)
                    case 0 { node := hashPair(node, sibling) }
                    case 1 { node := hashPair(sibling, node) }
                }

                newMemRoot_ := node
            }
            return newMemRoot_;
        }
    }

    /**
     * @notice Verify a memory proof without reading/writing.
     * @param _memRoot The expected memory Merkle root.
     * @param _addr The address being proven.
     * @param _proofOffset The offset of the memory proof in calldata.
     * @return valid_ Whether the proof is valid.
     */
    function isValidProof(
        bytes32 _memRoot,
        uint64 _addr,
        uint256 _proofOffset
    ) internal pure returns (bool valid_) {
        (, valid_) = readMemUnchecked(_memRoot, _addr, _proofOffset);
    }

    /**
     * @notice Compute the offset of a memory proof in calldata.
     * @param _proofDataOffset The base offset of all memory proofs.
     * @param _proofIndex The index of the proof (0, 1, 2, ...).
     * @return offset_ The offset of the specified proof.
     */
    function memoryProofOffset(
        uint256 _proofDataOffset,
        uint8 _proofIndex
    ) internal pure returns (uint256 offset_) {
        unchecked {
            // Each proof is MEM_PROOF_LEAF_COUNT * 32 bytes
            offset_ = _proofDataOffset + (uint256(_proofIndex) * (MEM_PROOF_LEAF_COUNT * 32));
            return offset_;
        }
    }

    /**
     * @notice Validate that enough calldata is available for a memory proof.
     * @param _proofStartOffset The starting offset of the proof in calldata.
     */
    function validateMemoryProofAvailability(uint256 _proofStartOffset) internal pure {
        unchecked {
            uint256 s = 0;
            assembly {
                s := calldatasize()
            }
            require(
                s >= (_proofStartOffset + MEM_PROOF_LEAF_COUNT * 32),
                "MIPSMemory: insufficient calldata for memory proof"
            );
        }
    }
}
