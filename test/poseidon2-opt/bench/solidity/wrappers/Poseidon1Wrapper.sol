// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {PoseidonT2} from "../vendored/poseidon1/PoseidonT2.sol";
import {PoseidonT3} from "../vendored/poseidon1/PoseidonT3.sol";
import {PoseidonT4} from "../vendored/poseidon1/PoseidonT4.sol";
import {PoseidonT5} from "../vendored/poseidon1/PoseidonT5.sol";
import {PoseidonT6} from "../vendored/poseidon1/PoseidonT6.sol";

/// @notice External wrapper for Poseidon1 (poseidon-solidity).
contract Poseidon1Wrapper {
    function hash_1(uint256 a) external pure returns (uint256) {
        return PoseidonT2.hash([a]);
    }

    function hash_2(uint256 a, uint256 b) external pure returns (uint256) {
        return PoseidonT3.hash([a, b]);
    }

    function hash_3(uint256 a, uint256 b, uint256 c) external pure returns (uint256) {
        return PoseidonT4.hash([a, b, c]);
    }

    function hash_4(uint256 a, uint256 b, uint256 c, uint256 d) external pure returns (uint256) {
        return PoseidonT5.hash([a, b, c, d]);
    }

    function hash_5(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) external pure returns (uint256) {
        return PoseidonT6.hash([a, b, c, d, e]);
    }
}
