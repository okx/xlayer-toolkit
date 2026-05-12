#!/bin/bash
# Cross-check: verify Solidity and Circom implementations produce identical outputs.
# Requires: circom, snarkjs, node, forge
#
# Usage: bash test/cross_check.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$REPO_ROOT/scripts/setup-libs.sh"
. "$REPO_ROOT/scripts/lib.sh"

detect_circom
require_command snarkjs "Install via: npm install -g snarkjs"
require_command node    "Install Node.js >= 18 (https://nodejs.org/)"
require_command forge   "Install Foundry: https://book.getfoundry.sh/getting-started/installation"

BUILD="$REPO_ROOT/bench/circom/build_crosscheck"
CIRCUITS="$REPO_ROOT/bench/circom/circuits"
TMP_SOL="$REPO_ROOT/test/_CrossCheckTmp.t.sol"
PASS=0
FAIL=0

# Clean up the per-call temp test file even on Ctrl+C, SIGTERM, or `set -e` aborts.
trap 'rm -f "$TMP_SOL"' EXIT INT TERM

mkdir -p "$BUILD"

# ── Helpers ──

# Compile circom circuit, generate witness, return output[0]
circom_output() {
    local LABEL=$1 CIRCUIT=$2 INPUT_JSON=$3
    local NAME=$(basename "$CIRCUIT" .circom)
    local SLUG
    SLUG=$(slugify "$LABEL")
    local DIR="$BUILD/$SLUG"
    mkdir -p "$DIR"

    if [ ! -f "$DIR/${NAME}_js/${NAME}.wasm" ]; then
        $CIRCOM "$CIRCUIT" --wasm -o "$DIR" >/dev/null
    fi

    echo "$INPUT_JSON" > "$DIR/input.json"
    node "$DIR/${NAME}_js/generate_witness.js" \
         "$DIR/${NAME}_js/${NAME}.wasm" \
         "$DIR/input.json" \
         "$DIR/witness.wtns" >/dev/null

    snarkjs wtns export json "$DIR/witness.wtns" "$DIR/witness.json" >/dev/null
    node -p "require('$DIR/witness.json')[1]"
}

# Run a Solidity expression via a temporary forge test, return the numeric result
solidity_output() {
    local SOL_CALL=$1
    cat > "$TMP_SOL" << SOLEOF
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;
import {Test, console} from "forge-std/Test.sol";
import {Poseidon2T2} from "../src/solidity/Poseidon2T2.sol";
import {Poseidon2T2FF} from "../src/solidity/Poseidon2T2FF.sol";
import {Poseidon2T3} from "../src/solidity/Poseidon2T3.sol";
import {Poseidon2T4} from "../src/solidity/Poseidon2T4.sol";
import {Poseidon2T4Sponge} from "../src/solidity/Poseidon2T4Sponge.sol";
import {Poseidon2T8} from "../src/solidity/Poseidon2T8.sol";
contract CrossCheckTmp is Test {
    function test_crosscheck() public pure {
        console.log("XCHECK:", ${SOL_CALL});
    }
}
SOLEOF
    # Tolerate forge test failure: an empty OUT downstream surfaces as MISMATCH
    # in compare(), preserving the existing soft-fail UX. Without `|| true`,
    # `set -o pipefail` would make the whole script abort on the first
    # compilation error inside the temp test.
    local OUT
    OUT=$( { forge test --match-test test_crosscheck --match-contract CrossCheckTmp -vv 2>&1 \
        | grep "XCHECK:" | awk '{print $NF}'; } || true )
    rm -f "$TMP_SOL"
    echo "$OUT"
}

# Compare circom and solidity outputs
compare() {
    local LABEL=$1 SOL_CALL=$2 CIRCUIT=$3 INPUT_JSON=$4

    local CIRCOM_VAL
    CIRCOM_VAL=$(circom_output "$LABEL" "$CIRCUIT" "$INPUT_JSON")
    local SOL_VAL
    SOL_VAL=$(solidity_output "$SOL_CALL")

    if [ "$CIRCOM_VAL" = "$SOL_VAL" ]; then
        printf "  PASS  %-30s %s\n" "$LABEL" "$SOL_VAL"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %-30s MISMATCH\n" "$LABEL"
        printf "        Solidity: %s\n" "$SOL_VAL"
        printf "        Circom:   %s\n" "$CIRCOM_VAL"
        FAIL=$((FAIL + 1))
    fi
}

# ── Pre-build Solidity ──
echo "Building Solidity..."
forge build --quiet

echo ""
echo "============================================"
echo "  Solidity <-> Circom Cross-Check"
echo "============================================"
echo ""

# ── T2 hash1 ──
compare "T2 hash1(0)" \
    "Poseidon2T2.hash1(0)" \
    "$CIRCUITS/bench_t2_hash1.circom" \
    '{"a0": "0"}'

compare "T2 hash1(42)" \
    "Poseidon2T2.hash1(42)" \
    "$CIRCUITS/bench_t2_hash1.circom" \
    '{"a0": "42"}'

# ── T2FF compress ──
compare "T2FF compress(1,2)" \
    "Poseidon2T2FF.compress(1, 2)" \
    "$CIRCUITS/bench_t2ff_compress.circom" \
    '{"a0": "1", "a1": "2"}'

# ── T3 hash2 ──
compare "T3 hash2(0,0)" \
    "Poseidon2T3.hash2(0, 0)" \
    "$CIRCUITS/bench_t3_hash2.circom" \
    '{"a0": "0", "a1": "0"}'

compare "T3 hash2(1,2)" \
    "Poseidon2T3.hash2(1, 2)" \
    "$CIRCUITS/bench_t3_hash2.circom" \
    '{"a0": "1", "a1": "2"}'

# ── T4 hash3 ──
compare "T4 hash3(1,2,3)" \
    "Poseidon2T4.hash3(1, 2, 3)" \
    "$CIRCUITS/bench_t4_hash3.circom" \
    '{"a0": "1", "a1": "2", "a2": "3"}'

# ── T4S sponge hash3 ──
compare "T4S hash3(1,2,3)" \
    "Poseidon2T4Sponge.hash3(1, 2, 3)" \
    "$CIRCUITS/bench_opt_hash3.circom" \
    '{"inputs": ["1", "2", "3"]}'

# ── T8 hash7 ──
compare "T8 hash7(1..7)" \
    "Poseidon2T8.hash7(1, 2, 3, 4, 5, 6, 7)" \
    "$CIRCUITS/bench_t8_hash7.circom" \
    '{"a0":"1","a1":"2","a2":"3","a3":"4","a4":"5","a5":"6","a6":"7"}'

compare "T8 hash7(0*7)" \
    "Poseidon2T8.hash7(0, 0, 0, 0, 0, 0, 0)" \
    "$CIRCUITS/bench_t8_hash7.circom" \
    '{"a0":"0","a1":"0","a2":"0","a3":"0","a4":"0","a5":"0","a6":"0"}'

# ── Optional fuzz mode: boundary sweep + random uint256 inputs ──
# Opt in via env var: `CROSS_CHECK_FUZZ=N bash test/cross_check.sh`
# Adds 6 boundary compares per library (≈ 30s × 6 × 6 = 6 min) plus N random
# iterations (each ≈ 60s).
#
# Boundary sweep is critical: pure-random uniform sampling over uint256 has
# negligible probability of hitting interesting edges. The boundary set targets
# values that exercise input mod reduction, dirty-value tracking, and uint256
# overflow paths — values Foundry's fuzzer would auto-include via dictionary
# extraction but bash cannot.
if [ -n "${CROSS_CHECK_FUZZ:-}" ] && [ "${CROSS_CHECK_FUZZ}" -ge 0 ] 2>/dev/null; then
    require_command python3 "Install Python 3 (https://www.python.org/) — used to generate random uint256 fuzz inputs"
    echo ""
    echo "============================================"
    echo "  Fuzz mode: boundary sweep + ${CROSS_CHECK_FUZZ} random input(s) per library"
    echo "============================================"
    echo ""

    # Use decimal literals on both sides — Solidity natively accepts large
    # decimal literals as uint256, eliminating any chance of hand-computed hex
    # values disagreeing with their decimal counterparts (this code originally
    # had separate _DEC and _HEX constants and a typo'd 3*PRIME hex caused 6
    # silent mismatches).
    boundary_run() {
        local D=$1 LBL=$2

        compare "boundary[$LBL] T2 hash1" \
            "Poseidon2T2.hash1($D)" \
            "$CIRCUITS/bench_t2_hash1.circom" \
            "{\"a0\": \"$D\"}"

        compare "boundary[$LBL] T2FF compress" \
            "Poseidon2T2FF.compress($D, $D)" \
            "$CIRCUITS/bench_t2ff_compress.circom" \
            "{\"a0\": \"$D\", \"a1\": \"$D\"}"

        compare "boundary[$LBL] T3 hash2" \
            "Poseidon2T3.hash2($D, $D)" \
            "$CIRCUITS/bench_t3_hash2.circom" \
            "{\"a0\": \"$D\", \"a1\": \"$D\"}"

        compare "boundary[$LBL] T4 hash3" \
            "Poseidon2T4.hash3($D, $D, $D)" \
            "$CIRCUITS/bench_t4_hash3.circom" \
            "{\"a0\": \"$D\", \"a1\": \"$D\", \"a2\": \"$D\"}"

        compare "boundary[$LBL] T4S hash3" \
            "Poseidon2T4Sponge.hash3($D, $D, $D)" \
            "$CIRCUITS/bench_opt_hash3.circom" \
            "{\"inputs\": [\"$D\", \"$D\", \"$D\"]}"

        compare "boundary[$LBL] T8 hash7" \
            "Poseidon2T8.hash7($D, $D, $D, $D, $D, $D, $D)" \
            "$CIRCUITS/bench_t8_hash7.circom" \
            "{\"a0\":\"$D\",\"a1\":\"$D\",\"a2\":\"$D\",\"a3\":\"$D\",\"a4\":\"$D\",\"a5\":\"$D\",\"a6\":\"$D\"}"
    }

    # Boundary values that pure-uniform random would never hit, but matter
    # for correctness of input reduction and dirty-value tracking.
    boundary_run 21888242871839275222246405745257275088548364400416034343698204186575808495616  "PRIME-1"
    boundary_run 21888242871839275222246405745257275088548364400416034343698204186575808495617  "PRIME"
    boundary_run 21888242871839275222246405745257275088548364400416034343698204186575808495618  "PRIME+1"
    boundary_run 65664728615517825666739217235771825265645093201248103031094612559727425486851  "3*PRIME"
    boundary_run 115792089237316195423570985008687907853269984665640564039457584007913129639935 "uint256_max"
    boundary_run 115792089237316195423570985008687907853269984665640564039457584007913129639934 "uint256_max-1"

    rand_dec() { python3 -c "import secrets; print(secrets.randbits(256))"; }

    # bash arithmetic — safe at 0 / negative; macOS BSD `seq 1 0` reverses to "1 0".
    for ((i=1; i<=CROSS_CHECK_FUZZ; i++)); do
        d_a=$(rand_dec); d_b=$(rand_dec); d_c=$(rand_dec)
        d_d=$(rand_dec); d_e=$(rand_dec); d_f=$(rand_dec); d_g=$(rand_dec)

        compare "fuzz[$i] T2 hash1" \
            "Poseidon2T2.hash1($d_a)" \
            "$CIRCUITS/bench_t2_hash1.circom" \
            "{\"a0\": \"$d_a\"}"

        compare "fuzz[$i] T2FF compress" \
            "Poseidon2T2FF.compress($d_a, $d_b)" \
            "$CIRCUITS/bench_t2ff_compress.circom" \
            "{\"a0\": \"$d_a\", \"a1\": \"$d_b\"}"

        compare "fuzz[$i] T3 hash2" \
            "Poseidon2T3.hash2($d_a, $d_b)" \
            "$CIRCUITS/bench_t3_hash2.circom" \
            "{\"a0\": \"$d_a\", \"a1\": \"$d_b\"}"

        compare "fuzz[$i] T4 hash3" \
            "Poseidon2T4.hash3($d_a, $d_b, $d_c)" \
            "$CIRCUITS/bench_t4_hash3.circom" \
            "{\"a0\": \"$d_a\", \"a1\": \"$d_b\", \"a2\": \"$d_c\"}"

        compare "fuzz[$i] T4S hash3" \
            "Poseidon2T4Sponge.hash3($d_a, $d_b, $d_c)" \
            "$CIRCUITS/bench_opt_hash3.circom" \
            "{\"inputs\": [\"$d_a\", \"$d_b\", \"$d_c\"]}"

        compare "fuzz[$i] T8 hash7" \
            "Poseidon2T8.hash7($d_a, $d_b, $d_c, $d_d, $d_e, $d_f, $d_g)" \
            "$CIRCUITS/bench_t8_hash7.circom" \
            "{\"a0\":\"$d_a\",\"a1\":\"$d_b\",\"a2\":\"$d_c\",\"a3\":\"$d_d\",\"a4\":\"$d_e\",\"a5\":\"$d_f\",\"a6\":\"$d_g\"}"
    done
fi

echo ""
echo "============================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================"

# Clean up
rm -f "$REPO_ROOT/test/_CrossCheckTmp.t.sol"

[ "$FAIL" -eq 0 ] || exit 1
