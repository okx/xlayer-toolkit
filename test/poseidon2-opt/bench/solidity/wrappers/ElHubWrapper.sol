// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProofHash} from "../vendored/ElHubProofHash.sol";

contract ElHubWrapper {
    function hash2(uint256 a, uint256 b) external pure returns (uint256) {
        return ProofHash.hashPair(a, b);
    }
}
