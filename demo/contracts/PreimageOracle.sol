// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPreimageOracle} from "./interfaces/IPreimageOracle.sol";
import {PreimageKeyLib} from "./libraries/PreimageKeyLib.sol";
import {PartOffsetOOB} from "./libraries/CannonErrors.sol";

/**
 * @title PreimageOracle
 * @notice Stores preimages for Cannon VM execution and step proof verification.
 * @dev Preimages are stored by their keccak256 hash.
 *      The preimage key format:
 *      - Type 1 (0x01): Local data - keccak256(ident || caller || localContext)
 *      - Type 2 (0x02): Keccak256 hash
 *      
 *      Preimage data format in storage:
 *      - First 8 bytes: big-endian uint64 length prefix
 *      - Remaining bytes: actual preimage data
 */
contract PreimageOracle is IPreimageOracle {
    /// @notice Mapping of preimage hashes to their lengths
    mapping(bytes32 => uint256) public preimageLengths;

    /// @notice Mapping of preimage hashes to part offsets to parts (32-byte chunks)
    mapping(bytes32 => mapping(uint256 => bytes32)) public preimageParts;

    /// @notice Mapping of preimage hashes to part offsets to readiness flags
    mapping(bytes32 => mapping(uint256 => bool)) public preimagePartOk;

    /// @notice Event emitted when a preimage part is loaded
    event PreimagePartLoaded(bytes32 indexed key, uint256 offset, uint256 length);

    /**
     * @notice Load a local data preimage part into the oracle.
     * @param _ident The identifier for the preimage (used to derive the key).
     * @param _localContext The local context for the preimage.
     * @param _word The preimage part (32 bytes).
     * @param _size The total size of the preimage.
     * @param _partOffset The offset of this part in the preimage.
     * @return key_ The computed preimage key.
     * 
     * @dev Local data identifiers for Cannon:
     *      1: L1 Head Hash (bytes32)
     *      2: Output Root (bytes32)
     *      3: Root Claim (bytes32)
     *      4: L2 Block Number (uint64)
     *      5: Chain ID (uint64)
     */
    function loadLocalData(
        uint256 _ident,
        bytes32 _localContext,
        bytes32 _word,
        uint256 _size,
        uint256 _partOffset
    ) external returns (bytes32 key_) {
        // Compute the localized key
        key_ = PreimageKeyLib.localizeIdent(_ident, _localContext);

        // Revert if the given part offset is not within bounds.
        // Add 8 for the length-prefix part
        if (_partOffset >= _size + 8 || _size > 32) {
            revert PartOffsetOOB();
        }

        // Prepare the local data part at the given offset
        bytes32 part;
        assembly {
            // Clean the memory in [0x20, 0x40)
            mstore(0x20, 0x00)

            // Store the full local data in scratch space.
            // First 8 bytes: big-endian length prefix
            mstore(0x00, shl(192, _size))
            // Next bytes: the actual data word
            mstore(0x08, _word)

            // Prepare the local data part at the requested offset.
            part := mload(_partOffset)
        }

        // Store the first part with `_partOffset`.
        preimagePartOk[key_][_partOffset] = true;
        preimageParts[key_][_partOffset] = part;
        // Assign the length of the preimage at the localized key.
        preimageLengths[key_] = _size;

        emit PreimagePartLoaded(key_, _partOffset, _size);
    }

    /**
     * @notice Load a keccak256 preimage part into the oracle.
     * @param _partOffset The offset of the part to load.
     * @param _preimage The full preimage data.
     * 
     * @dev The stored preimage includes an 8-byte big-endian length prefix.
     *      So the actual data starts at offset 8.
     */
    function loadKeccak256PreimagePart(
        uint256 _partOffset,
        bytes calldata _preimage
    ) external {
        uint256 size;
        bytes32 key;
        bytes32 part;
        assembly {
            // len(sig) + len(partOffset) + len(preimage offset) = 4 + 32 + 32 = 0x44
            size := calldataload(0x44)

            // revert if part offset >= size+8 (i.e. parts must be within bounds)
            if iszero(lt(_partOffset, add(size, 8))) {
                // Store "PartOffsetOOB()"
                mstore(0x00, 0xfe254987)
                // Revert with "PartOffsetOOB()"
                revert(0x1c, 0x04)
            }
            // we leave solidity slots 0x40 and 0x60 untouched, and everything after as scratch-memory.
            let ptr := 0x80
            // put size as big-endian uint64 at start of pre-image
            mstore(ptr, shl(192, size))
            ptr := add(ptr, 0x08)
            // copy preimage payload into memory so we can hash and read it.
            calldatacopy(ptr, _preimage.offset, size)
            // Note that it includes the 8-byte big-endian uint64 length prefix.
            // this will be zero-padded at the end, since memory at end is clean.
            part := mload(add(sub(ptr, 0x08), _partOffset))
            let h := keccak256(ptr, size) // compute preimage keccak256 hash
            // mask out prefix byte, replace with type 2 byte
            key := or(and(h, not(shl(248, 0xFF))), shl(248, 0x02))
        }
        preimagePartOk[key][_partOffset] = true;
        preimageParts[key][_partOffset] = part;
        preimageLengths[key] = size;

        emit PreimagePartLoaded(key, _partOffset, size);
    }

    /**
     * @notice Load a preimage part with SHA-256 hash key.
     * @param _partOffset The offset of the part to load.
     * @param _preimage The full preimage data.
     */
    function loadSha256PreimagePart(uint256 _partOffset, bytes calldata _preimage) external {
        uint256 size;
        bytes32 key;
        bytes32 part;
        assembly {
            // len(sig) + len(partOffset) + len(preimage offset) = 4 + 32 + 32 = 0x44
            size := calldataload(0x44)

            // revert if part offset >= size+8 (i.e. parts must be within bounds)
            if iszero(lt(_partOffset, add(size, 8))) {
                // Store "PartOffsetOOB()"
                mstore(0, 0xfe254987)
                // Revert with "PartOffsetOOB()"
                revert(0x1c, 4)
            }
            // we leave solidity slots 0x40 and 0x60 untouched,
            // and everything after as scratch-memory.
            let ptr := 0x80
            // put size as big-endian uint64 at start of pre-image
            mstore(ptr, shl(192, size))
            ptr := add(ptr, 8)
            // copy preimage payload into memory so we can hash and read it.
            calldatacopy(ptr, _preimage.offset, size)
            // Note that it includes the 8-byte big-endian uint64 length prefix.
            // this will be zero-padded at the end, since memory at end is clean.
            part := mload(add(sub(ptr, 8), _partOffset))

            // compute SHA2-256 hash with pre-compile
            let success :=
                staticcall(
                    gas(), // Forward all available gas
                    0x02, // Address of SHA-256 precompile
                    ptr, // Start of input data in memory
                    size, // Size of input data
                    0, // Store output in scratch memory
                    0x20 // Output is always 32 bytes
                )
            // Check if the staticcall succeeded
            if iszero(success) { revert(0, 0) }
            let h := mload(0) // get return data
            // mask out prefix byte, replace with type 4 byte
            key := or(and(h, not(shl(248, 0xFF))), shl(248, 4))
        }
        preimagePartOk[key][_partOffset] = true;
        preimageParts[key][_partOffset] = part;
        preimageLengths[key] = size;

        emit PreimagePartLoaded(key, _partOffset, size);
    }

    /**
     * @notice Read a preimage part from the oracle.
     * @param _key The preimage key.
     * @param _offset The offset to read from.
     * @return dat_ The 32-byte part at the given offset.
     * @return datLen_ The length of the readable data (clamped to preimage length).
     */
    function readPreimage(
        bytes32 _key,
        uint256 _offset
    ) external view returns (bytes32 dat_, uint256 datLen_) {
        require(preimagePartOk[_key][_offset], "pre-image must exist");

        // Calculate the length of the pre-image data
        // Add 8 for the length-prefix part
        datLen_ = 32;
        uint256 length = preimageLengths[_key];
        if (_offset + 32 >= length + 8) {
            datLen_ = length + 8 - _offset;
        }

        // Retrieve the pre-image data
        dat_ = preimageParts[_key][_offset];
    }

    /**
     * @notice Get the length of a preimage.
     * @param _key The preimage key.
     * @return The length of the preimage (without the 8-byte length prefix).
     */
    function preimageLength(bytes32 _key) external view returns (uint256) {
        return preimageLengths[_key];
    }

    /**
     * @notice Check if a preimage part is available.
     * @param _key The preimage key.
     * @param _offset The offset to check.
     * @return Whether the preimage part is available.
     */
    function isPartAvailable(bytes32 _key, uint256 _offset) external view returns (bool) {
        return preimagePartOk[_key][_offset];
    }
}
