// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @notice Interface for circomlibjs-generated Poseidon contracts.
/// @dev All circomlibjs contracts expose: poseidon(uint256[N]) returns (uint256)
interface IP1Cljs1 { function poseidon(uint256[1] memory) external pure returns (uint256); }
interface IP1Cljs2 { function poseidon(uint256[2] memory) external pure returns (uint256); }
interface IP1Cljs3 { function poseidon(uint256[3] memory) external pure returns (uint256); }
interface IP1Cljs4 { function poseidon(uint256[4] memory) external pure returns (uint256); }
interface IP1Cljs5 { function poseidon(uint256[5] memory) external pure returns (uint256); }
interface IP1Cljs6 { function poseidon(uint256[6] memory) external pure returns (uint256); }
