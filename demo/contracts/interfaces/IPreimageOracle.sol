// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPreimageOracle
/// @notice Interface for the PreimageOracle contract.
interface IPreimageOracle {
    /// @notice Reads a preimage from the oracle.
    /// @param _key The key of the preimage to read.
    /// @param _offset The offset of the preimage to read.
    /// @return dat_ The preimage data.
    /// @return datLen_ The length of the preimage data.
    function readPreimage(bytes32 _key, uint256 _offset) external view returns (bytes32 dat_, uint256 datLen_);

    /// @notice Loads local data parts into the preimage oracle.
    /// @param _ident The identifier of the local data.
    /// @param _localContext The local key context for the preimage oracle.
    /// @param _word The local data word.
    /// @param _size The number of bytes in `_word` to load.
    /// @param _partOffset The offset of the local data part to write to the oracle.
    /// @return key_ The key of the loaded preimage.
    function loadLocalData(
        uint256 _ident,
        bytes32 _localContext,
        bytes32 _word,
        uint256 _size,
        uint256 _partOffset
    ) external returns (bytes32 key_);

    /// @notice Prepares a preimage to be read by keccak256 key.
    /// @param _partOffset The offset of the preimage to read.
    /// @param _preimage The preimage data.
    function loadKeccak256PreimagePart(uint256 _partOffset, bytes calldata _preimage) external;

    /// @notice Returns the length of a preimage.
    /// @param _key The key of the preimage.
    /// @return The length of the preimage.
    function preimageLengths(bytes32 _key) external view returns (uint256);

    /// @notice Returns whether a preimage part is available.
    /// @param _key The key of the preimage.
    /// @param _offset The offset of the preimage part.
    /// @return Whether the preimage part is available.
    function preimagePartOk(bytes32 _key, uint256 _offset) external view returns (bool);
}
