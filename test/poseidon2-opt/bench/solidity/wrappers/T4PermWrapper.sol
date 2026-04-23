// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Poseidon2T4} from "../../../src/solidity/Poseidon2T4.sol";

contract T4PermWrapper {
    function hash3(uint256 a0, uint256 a1, uint256 a2) external pure returns (uint256) {
        return Poseidon2T4.hash3(a0, a1, a2);
    }
}
