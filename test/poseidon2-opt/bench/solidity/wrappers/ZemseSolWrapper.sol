// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Field} from "poseidon2-evm/Field.sol";
import {Poseidon2Lib} from "poseidon2-evm/Poseidon2Lib.sol";

/// @notice External wrapper for zemse's pure Solidity Poseidon2 implementation.
contract ZemseSolWrapper {
    using Field for *;

    function hash_1(uint256 x) external pure returns (uint256) {
        return Poseidon2Lib.hash_1(Field.Type.wrap(x)).toUint256();
    }

    function hash_2(uint256 x, uint256 y) external pure returns (uint256) {
        return Poseidon2Lib.hash_2(Field.Type.wrap(x), Field.Type.wrap(y)).toUint256();
    }

    function hash_3(uint256 x, uint256 y, uint256 z) external pure returns (uint256) {
        return Poseidon2Lib.hash_3(Field.Type.wrap(x), Field.Type.wrap(y), Field.Type.wrap(z)).toUint256();
    }
}
