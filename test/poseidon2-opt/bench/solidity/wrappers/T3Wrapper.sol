// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Poseidon2T3} from "../../../src/solidity/Poseidon2T3.sol";

contract T3Wrapper {
    function hash2(uint256 a0, uint256 a1) external pure returns (uint256) {
        return Poseidon2T3.hash2(a0, a1);
    }
}
