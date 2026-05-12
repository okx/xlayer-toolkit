// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Poseidon2T2FF} from "../../../src/solidity/Poseidon2T2FF.sol";

/// @notice External wrapper for optimized Poseidon2 compress (t=2, feed-forward).
contract CompressWrapper {
    function compress(uint256 left, uint256 right) external pure returns (uint256) {
        return Poseidon2T2FF.compress(left, right);
    }
}
