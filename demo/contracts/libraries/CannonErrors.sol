// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Thrown when a passed part offset is out of bounds.
error PartOffsetOOB();

/// @notice Thrown when insufficient gas is provided when loading precompile preimages.
error NotEnoughGas();

/// @notice Thrown when a merkle proof fails to verify.
error InvalidProof();

/// @notice Thrown when the prestate preimage doesn't match the claimed preimage.
error InvalidPreimage();

/// @notice Thrown when a leaf with an invalid input size is added.
error InvalidInputSize();

/// @notice Thrown when the value of the exited boolean is not 0 or 1.
error InvalidExitedValue();

/// @notice Thrown when reading an invalid memory
error InvalidMemoryProof();

/// @notice Thrown when the second memory location is invalid
error InvalidSecondMemoryProof();

/// @notice Thrown when an RMW instruction is expected, but a different instruction is provided.
error InvalidRMWInstruction();

/// @notice Thrown when the state version set is not supported.
error UnsupportedStateVersion();
