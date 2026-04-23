// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";
import {ZemseSolWrapper} from "../bench/solidity/wrappers/ZemseSolWrapper.sol";
import {ZemseYulWrapper} from "../bench/solidity/wrappers/ZemseYulWrapper.sol";
import {VkhWrapper} from "../bench/solidity/wrappers/VkhWrapper.sol";
import {OptimizedWrapper} from "../bench/solidity/wrappers/OptimizedWrapper.sol";
import {Poseidon2T2} from "../src/solidity/Poseidon2T2.sol";
import {Poseidon2T2FF} from "../src/solidity/Poseidon2T2FF.sol";
import {Poseidon2T3} from "../src/solidity/Poseidon2T3.sol";
import {Poseidon2T4} from "../src/solidity/Poseidon2T4.sol";
import {Poseidon2T4Sponge} from "../src/solidity/Poseidon2T4Sponge.sol";
import {Poseidon2T8} from "../src/solidity/Poseidon2T8.sol";

/// @notice Verify all implementations produce correct and consistent outputs.
contract CorrectnessTest is Test {
    ZemseSolWrapper internal zemseSol;
    ZemseYulWrapper internal zemseYul;
    VkhWrapper internal vkh;
    OptimizedWrapper internal optimized;

    uint256 constant PRIME = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;

    function setUp() public {
        zemseSol = new ZemseSolWrapper();
        zemseYul = new ZemseYulWrapper();
        vkh = new VkhWrapper();
        optimized = new OptimizedWrapper();
    }

    // ================================================================
    //  T4/T4S cross-implementation correctness (Noir RC)
    //  Compare our T4Sponge against zemse and V-k-h implementations.
    // ================================================================

    function test_T4S_vs_zemse_vkh_hash1() public view {
        uint256[4] memory inputs = [uint256(0), 1, 42, PRIME - 1];
        for (uint256 i = 0; i < inputs.length; i++) {
            uint256 a = zemseSol.hash_1(inputs[i]);
            uint256 b = zemseYul.hash_1(inputs[i]);
            uint256 c = vkh.hash_1(inputs[i]);
            uint256 d = optimized.hash_1(inputs[i]);
            assertEq(a, b, "zemseSol vs zemseYul hash1");
            assertEq(a, c, "zemseSol vs vkh hash1");
            assertEq(a, d, "zemseSol vs T4S hash1");
        }
    }

    function test_T4S_vs_zemse_vkh_hash2() public view {
        uint256[2][4] memory inputs = [
            [uint256(0), uint256(0)],
            [uint256(1), uint256(2)],
            [uint256(42), uint256(99)],
            [PRIME - 1, PRIME - 2]
        ];
        for (uint256 i = 0; i < inputs.length; i++) {
            uint256 a = zemseSol.hash_2(inputs[i][0], inputs[i][1]);
            uint256 b = zemseYul.hash_2(inputs[i][0], inputs[i][1]);
            uint256 c = vkh.hash_2(inputs[i][0], inputs[i][1]);
            uint256 d = optimized.hash_2(inputs[i][0], inputs[i][1]);
            assertEq(a, b, "zemseSol vs zemseYul hash2");
            assertEq(a, c, "zemseSol vs vkh hash2");
            assertEq(a, d, "zemseSol vs T4S hash2");
        }
    }

    function test_T4S_vs_zemse_vkh_hash3() public view {
        uint256[3][4] memory inputs = [
            [uint256(0), uint256(0), uint256(0)],
            [uint256(1), uint256(2), uint256(3)],
            [uint256(42), uint256(99), uint256(7)],
            [PRIME - 1, PRIME - 2, PRIME - 3]
        ];
        for (uint256 i = 0; i < inputs.length; i++) {
            uint256 a = zemseSol.hash_3(inputs[i][0], inputs[i][1], inputs[i][2]);
            uint256 b = zemseYul.hash_3(inputs[i][0], inputs[i][1], inputs[i][2]);
            uint256 c = vkh.hash_3(inputs[i][0], inputs[i][1], inputs[i][2]);
            uint256 d = optimized.hash_3(inputs[i][0], inputs[i][1], inputs[i][2]);
            assertEq(a, b, "zemseSol vs zemseYul hash3");
            assertEq(a, c, "zemseSol vs vkh hash3");
            assertEq(a, d, "zemseSol vs T4S hash3");
        }
    }

    // ================================================================
    //  T2 / T2FF / T3 regression tests (HorizenLabs RC)
    //  Test vectors captured from verified implementation.
    // ================================================================

    function test_T2_hash1_vectors() public pure {
        assertEq(
            Poseidon2T2.hash1(0),
            0x228981b886e5effb2c05a6be7ab4a05fde6bf702a2d039e46c87057dd729ef97,
            "T2 hash1(0)"
        );
        assertEq(
            Poseidon2T2.hash1(42),
            0x1efdde2c3496d09557a1cd8548bbaef7174b73cd80784ca94a02e6f57454fbb2,
            "T2 hash1(42)"
        );
        // Boundary: hash1(PRIME - 1)
        uint256 result = Poseidon2T2.hash1(PRIME - 1);
        assertTrue(result < PRIME, "T2 hash1 output must be < PRIME");
    }

    function test_T2FF_compress_vectors() public pure {
        assertEq(
            Poseidon2T2FF.compress(1, 2),
            0x0e90c132311e864e0c8bca37976f28579a2dd9436bbc11326e21ec7c00cea5b3,
            "T2FF compress(1,2)"
        );
        // Symmetry check: compress(a,b) != compress(b,a) (not commutative)
        assertTrue(
            Poseidon2T2FF.compress(1, 2) != Poseidon2T2FF.compress(2, 1),
            "T2FF compress must not be commutative"
        );
    }

    function test_T3_hash2_vectors() public pure {
        assertEq(
            Poseidon2T3.hash2(0, 0),
            0x2ed1da00b14d635bd35b88ab49390d5c13c90da7e9e3a5f1ea69cd87a0aa3e82,
            "T3 hash2(0,0)"
        );
        assertEq(
            Poseidon2T3.hash2(1, 2),
            0x2afac3bdc3663b71eefeecdf21b147d0ba7dd7a169a7757c05ed6bfb065bffd2,
            "T3 hash2(1,2)"
        );
    }

    // ================================================================
    //  T4 vs T4S consistency (Noir RC, capacity=0 vs sponge IV)
    //  T4 hash3(a,b,c) = perm(a,b,c,0)[0]
    //  T4S hash3(a,b,c) = perm(a,b,c, 3<<64)[0] (sponge IV)
    //  They should NOT be equal (different capacity initialization).
    // ================================================================

    function test_T4_vs_T4S_different_capacity() public pure {
        uint256 t4 = Poseidon2T4.hash3(1, 2, 3);
        uint256 t4s = Poseidon2T4Sponge.hash3(1, 2, 3);
        assertTrue(t4 != t4s, "T4 and T4S should differ (capacity=0 vs sponge IV)");

        // Verify known values
        assertEq(t4, 0x27c494c0c0bcb07fb9734dd1c34d066a3fb293fe170e9575adeceed1abb08c94, "T4 hash3(1,2,3)");
        assertEq(t4s, 0x23864adb160dddf590f1d3303683ebcb914f828e2635f6e85a32f0a1aecd3dd8, "T4S hash3(1,2,3)");
    }

    function test_T4_hash3_vectors() public pure {
        assertEq(
            Poseidon2T4.hash3(1, 2, 3),
            0x27c494c0c0bcb07fb9734dd1c34d066a3fb293fe170e9575adeceed1abb08c94,
            "T4 hash3(1,2,3)"
        );
    }

    // ================================================================
    //  T8 regression tests (HorizenLabs RC, t=8)
    // ================================================================

    function test_T8_hash7_vectors() public pure {
        assertEq(
            Poseidon2T8.hash7(1, 2, 3, 4, 5, 6, 7),
            0x0d05edb4249fe4ca1e0489ca91eb0e35282f11c7460b9bd9213cd47ffd476bcd,
            "T8 hash7(1..7)"
        );
        // hash4_padded(1,2,3,4) = hash7(1,2,3,4,0,0,0)
        assertEq(
            Poseidon2T8.hash4_padded(1, 2, 3, 4),
            Poseidon2T8.hash7(1, 2, 3, 4, 0, 0, 0),
            "T8 hash4_padded consistency"
        );
        assertEq(
            Poseidon2T8.hash4_padded(1, 2, 3, 4),
            0x16f04762d6acd9ac38fc0ef4dfd85b6ae24a5427898963fb99dd2aed47ddbe24,
            "T8 hash4_padded(1,2,3,4)"
        );
    }

    // ================================================================
    //  Edge cases: overflow inputs
    // ================================================================

    function test_overflow_inputs() public view {
        uint256 max = type(uint256).max;

        // T4S: hash1(uint256.max) should match other implementations
        uint256 a = vkh.hash_1(max);
        uint256 b = optimized.hash_1(max);
        assertEq(a, b, "T4S hash1(uint256.max)");

        // T4S: hash1(PRIME) should equal hash1(0)
        uint256 c = vkh.hash_1(PRIME);
        uint256 d = optimized.hash_1(PRIME);
        assertEq(c, d, "T4S hash1(PRIME)");
        assertEq(c, vkh.hash_1(0), "hash1(PRIME) == hash1(0)");

        // T4S: hash2/hash3 with overflow
        assertEq(vkh.hash_2(max, max), optimized.hash_2(max, max), "T4S hash2(max,max)");
        assertEq(vkh.hash_3(max, PRIME + 5, PRIME), optimized.hash_3(max, PRIME + 5, PRIME), "T4S hash3 overflow");

        // T2: output must be in field
        assertTrue(Poseidon2T2.hash1(max) < PRIME, "T2 hash1(max) in field");
        assertTrue(Poseidon2T3.hash2(max, max) < PRIME, "T3 hash2(max,max) in field");
        assertTrue(Poseidon2T8.hash7(max, max, max, max, max, max, max) < PRIME, "T8 hash7(max*7) in field");
    }
}
