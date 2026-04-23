// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Poseidon2T4} from "poseidon2-solidity/Poseidon2T4.sol";

/// @notice External wrapper for V-k-h's Poseidon2 implementation.
contract VkhWrapper {
    function hash_1(uint256 x) external pure returns (uint256) {
        return Poseidon2T4.hash1(x);
    }

    function hash_2(uint256 x, uint256 y) external pure returns (uint256) {
        return Poseidon2T4.hash2(x, y);
    }

    function hash_3(uint256 x, uint256 y, uint256 z) external pure returns (uint256) {
        return Poseidon2T4.hash3(x, y, z);
    }

    function hash_4(uint256 a0, uint256 a1, uint256 a2, uint256 a3) external pure returns (uint256) {
        return Poseidon2T4.hash4(a0, a1, a2, a3);
    }

    function hash_5(uint256 a0, uint256 a1, uint256 a2, uint256 a3, uint256 a4) external pure returns (uint256) {
        return Poseidon2T4.hash5(a0, a1, a2, a3, a4);
    }

    function hash_6(uint256 a0, uint256 a1, uint256 a2, uint256 a3, uint256 a4, uint256 a5) external pure returns (uint256) {
        return Poseidon2T4.hash6(a0, a1, a2, a3, a4, a5);
    }

    function hash_7(uint256 a0, uint256 a1, uint256 a2, uint256 a3, uint256 a4, uint256 a5, uint256 a6) external pure returns (uint256) {
        return Poseidon2T4.hash7(a0, a1, a2, a3, a4, a5, a6);
    }

    function hash_8(uint256 a0, uint256 a1, uint256 a2, uint256 a3, uint256 a4, uint256 a5, uint256 a6, uint256 a7) external pure returns (uint256) {
        return Poseidon2T4.hash8(a0, a1, a2, a3, a4, a5, a6, a7);
    }

    function hash_9(uint256 a0, uint256 a1, uint256 a2, uint256 a3, uint256 a4, uint256 a5, uint256 a6, uint256 a7, uint256 a8) external pure returns (uint256) {
        return Poseidon2T4.hash9(a0, a1, a2, a3, a4, a5, a6, a7, a8);
    }
}
