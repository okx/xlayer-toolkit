// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Poseidon2T2} from "../../../src/solidity/Poseidon2T2.sol";

contract T2Wrapper {
    function hash1(uint256 x) external pure returns (uint256) {
        return Poseidon2T2.hash1(x);
    }
}
