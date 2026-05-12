// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";
import {Poseidon2T2} from "../src/solidity/Poseidon2T2.sol";
import {Poseidon2T2FF} from "../src/solidity/Poseidon2T2FF.sol";
import {Poseidon2T3} from "../src/solidity/Poseidon2T3.sol";
import {Poseidon2T4} from "../src/solidity/Poseidon2T4.sol";
import {Poseidon2T4Sponge} from "../src/solidity/Poseidon2T4Sponge.sol";
import {Poseidon2T8} from "../src/solidity/Poseidon2T8.sol";

/// @notice Property-based / fuzz coverage for our own libraries only.
///         No cross-implementation comparison here — that's handled by:
///           - test/cross_check.sh (Solidity ↔ Circom across our two implementations)
///           - test/Correctness.t.sol fixed-input tests against zemse / V-k-h.
///         Fuzz checks two invariants on every Poseidon2 library we ship:
///           1. Input modular invariance: hash(a) == hash(a % PRIME).
///           2. Output in-range:           hash(...) < PRIME.
contract FuzzTest is Test {
    uint256 constant PRIME = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;

    // ================================================================
    //  Poseidon2T2 — hash1
    // ================================================================

    function testFuzz_T2_invariants(uint256 a) public pure {
        uint256 h = Poseidon2T2.hash1(a);
        assertLt(h, PRIME, "T2 hash1: output not in field");
        assertEq(h, Poseidon2T2.hash1(a % PRIME), "T2 hash1: not invariant under input mod");
    }

    // ================================================================
    //  Poseidon2T2FF — compress (feed-forward)
    // ================================================================

    function testFuzz_T2FF_invariants(uint256 a, uint256 b) public pure {
        uint256 h = Poseidon2T2FF.compress(a, b);
        assertLt(h, PRIME, "T2FF compress: output not in field");
        assertEq(
            h,
            Poseidon2T2FF.compress(a % PRIME, b % PRIME),
            "T2FF compress: not invariant under input mod"
        );
    }

    // ================================================================
    //  Poseidon2T3 — hash2
    // ================================================================

    function testFuzz_T3_invariants(uint256 a, uint256 b) public pure {
        uint256 h = Poseidon2T3.hash2(a, b);
        assertLt(h, PRIME, "T3 hash2: output not in field");
        assertEq(
            h,
            Poseidon2T3.hash2(a % PRIME, b % PRIME),
            "T3 hash2: not invariant under input mod"
        );
    }

    // ================================================================
    //  Poseidon2T4 — hash3
    // ================================================================

    function testFuzz_T4_invariants(uint256 a, uint256 b, uint256 c) public pure {
        uint256 h = Poseidon2T4.hash3(a, b, c);
        assertLt(h, PRIME, "T4 hash3: output not in field");
        assertEq(
            h,
            Poseidon2T4.hash3(a % PRIME, b % PRIME, c % PRIME),
            "T4 hash3: not invariant under input mod"
        );
    }

    // ================================================================
    //  Poseidon2T4Sponge — hash3 (representative; sponge logic shared across hashN)
    // ================================================================

    function testFuzz_T4Sponge_invariants(uint256 a, uint256 b, uint256 c) public pure {
        uint256 h = Poseidon2T4Sponge.hash3(a, b, c);
        assertLt(h, PRIME, "T4Sponge hash3: output not in field");
        assertEq(
            h,
            Poseidon2T4Sponge.hash3(a % PRIME, b % PRIME, c % PRIME),
            "T4Sponge hash3: not invariant under input mod"
        );
    }

    // ================================================================
    //  Poseidon2T8 — hash7 (most stress: T8 has no explicit entry mod;
    //                       relies on first matmulM4 addmod for reduction)
    // ================================================================

    function testFuzz_T8_invariants(
        uint256 a0, uint256 a1, uint256 a2, uint256 a3,
        uint256 a4, uint256 a5, uint256 a6
    ) public pure {
        uint256 h = Poseidon2T8.hash7(a0, a1, a2, a3, a4, a5, a6);
        assertLt(h, PRIME, "T8 hash7: output not in field");
        assertEq(
            h,
            Poseidon2T8.hash7(
                a0 % PRIME, a1 % PRIME, a2 % PRIME,
                a3 % PRIME, a4 % PRIME, a5 % PRIME, a6 % PRIME
            ),
            "T8 hash7: not invariant under input mod (implicit reduction broken?)"
        );
    }
}
