// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PreimageKeyLib
/// @notice Library for computing preimage keys.
library PreimageKeyLib {
    /// @notice Masks out the high-order byte of a preimage key, and sets it to the localized key type.
    /// @param _ident The identifier of the local data.
    /// @param _localContext The local context for the key.
    /// @return localizedKey_ The localized preimage key.
    function localizeIdent(uint256 _ident, bytes32 _localContext) internal view returns (bytes32 localizedKey_) {
        assembly {
            // Set the type byte of the key to 1 (localized key type)
            // Compute keccak256(abi.encodePacked(ident, caller, localContext))
            mstore(0x00, _ident)
            mstore(0x20, caller())
            mstore(0x40, _localContext)
            localizedKey_ := or(shl(248, 0x01), and(keccak256(0x00, 0x60), not(shl(248, 0xFF))))
        }
    }

    /// @notice Computes a preimage key for a keccak256 hash.
    /// @param _preimage The preimage data.
    /// @return key_ The preimage key.
    function keccak256PreimageKey(bytes memory _preimage) internal pure returns (bytes32 key_) {
        bytes32 hash = keccak256(_preimage);
        // Set the type byte to 2 (keccak256 preimage)
        assembly {
            key_ := or(and(hash, not(shl(248, 0xFF))), shl(248, 0x02))
        }
    }
}
