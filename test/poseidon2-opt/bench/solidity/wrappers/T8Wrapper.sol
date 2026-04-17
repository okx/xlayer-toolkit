// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Poseidon2T8} from "../../../src/solidity/Poseidon2T8.sol";

contract T8Wrapper {
    function hash7(
        uint256 a0, uint256 a1, uint256 a2, uint256 a3,
        uint256 a4, uint256 a5, uint256 a6
    ) external pure returns (uint256) {
        return Poseidon2T8.hash7(a0, a1, a2, a3, a4, a5, a6);
    }

    // Padded variants — same permutation, unused slots = 0
    function hash4_padded(uint256 a0, uint256 a1, uint256 a2, uint256 a3) external pure returns (uint256) {
        return Poseidon2T8.hash7(a0, a1, a2, a3, 0, 0, 0);
    }

    function hash5_padded(uint256 a0, uint256 a1, uint256 a2, uint256 a3, uint256 a4) external pure returns (uint256) {
        return Poseidon2T8.hash7(a0, a1, a2, a3, a4, 0, 0);
    }

    function hash6_padded(uint256 a0, uint256 a1, uint256 a2, uint256 a3, uint256 a4, uint256 a5) external pure returns (uint256) {
        return Poseidon2T8.hash7(a0, a1, a2, a3, a4, a5, 0);
    }
}
