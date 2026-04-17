// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Field} from "poseidon2-evm/Field.sol";
import {Poseidon2Lib} from "poseidon2-evm/Poseidon2Lib.sol";
import {Poseidon2T4 as VkhPoseidon2T4} from "poseidon2-solidity/Poseidon2T4.sol";
import {LibPoseidon2Yul} from "../vendored/LibPoseidon2Yul.sol";
import {Poseidon2T4Sponge as OurPoseidon2T4Sponge} from "../../../src/solidity/Poseidon2T4Sponge.sol";

/// @notice Single contract that inlines all libraries for internal-call gas measurement.
contract InlineWrapper {
    using Field for *;

    // ── zemse Solidity (internal / inlined) ──

    function zemseSol_hash_1(uint256 x) external pure returns (uint256) {
        return Poseidon2Lib.hash_1(Field.Type.wrap(x)).toUint256();
    }

    function zemseSol_hash_2(uint256 x, uint256 y) external pure returns (uint256) {
        return Poseidon2Lib.hash_2(Field.Type.wrap(x), Field.Type.wrap(y)).toUint256();
    }

    function zemseSol_hash_3(uint256 x, uint256 y, uint256 z) external pure returns (uint256) {
        return Poseidon2Lib.hash_3(Field.Type.wrap(x), Field.Type.wrap(y), Field.Type.wrap(z)).toUint256();
    }

    // ── zemse Yul (internal / inlined) ──

    function zemseYul_hash_1(uint256 x) external pure returns (uint256) {
        return LibPoseidon2Yul.hash_1(x);
    }

    function zemseYul_hash_2(uint256 x, uint256 y) external pure returns (uint256) {
        return LibPoseidon2Yul.hash_2(x, y);
    }

    function zemseYul_hash_3(uint256 x, uint256 y, uint256 z) external pure returns (uint256) {
        return LibPoseidon2Yul.hash_3(x, y, z);
    }

    // ── Our Poseidon2T4 (internal / inlined) ──

    function optimized_hash_1(uint256 x) external pure returns (uint256) {
        return OurPoseidon2T4Sponge.hash1(x);
    }

    function optimized_hash_2(uint256 x, uint256 y) external pure returns (uint256) {
        return OurPoseidon2T4Sponge.hash2(x, y);
    }

    function optimized_hash_3(uint256 x, uint256 y, uint256 z) external pure returns (uint256) {
        return OurPoseidon2T4Sponge.hash3(x, y, z);
    }

    // ── V-k-h Poseidon2T4 (internal / inlined) ──

    function vkh_hash_1(uint256 x) external pure returns (uint256) {
        return VkhPoseidon2T4.hash1(x);
    }

    function vkh_hash_2(uint256 x, uint256 y) external pure returns (uint256) {
        return VkhPoseidon2T4.hash2(x, y);
    }

    function vkh_hash_3(uint256 x, uint256 y, uint256 z) external pure returns (uint256) {
        return VkhPoseidon2T4.hash3(x, y, z);
    }
}
