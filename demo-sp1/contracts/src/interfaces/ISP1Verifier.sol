// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title SP1 Verifier Interface
interface ISP1Verifier {
    /// @notice Verify a SP1 proof
    /// @param vkey The verification key
    /// @param publicValues The public values (ABI encoded)
    /// @param proofBytes The proof bytes
    function verifyProof(
        bytes32 vkey,
        bytes memory publicValues,
        bytes memory proofBytes
    ) external view;
}
