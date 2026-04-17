#!/bin/bash
# Cross-check: verify Solidity and Circom implementations produce identical outputs.
# Requires: circom, snarkjs, node, forge
#
# Usage: bash test/cross_check.sh
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CIRCOM=~/.cargo/bin/circom
BUILD="$REPO_ROOT/bench/circom/build_crosscheck"
CIRCUITS="$REPO_ROOT/bench/circom/circuits"
PASS=0
FAIL=0

mkdir -p "$BUILD"

# ── Helpers ──

# Compile circom circuit, generate witness, return output[0]
circom_output() {
    local LABEL=$1 CIRCUIT=$2 INPUT_JSON=$3
    local NAME=$(basename "$CIRCUIT" .circom)
    local DIR="$BUILD/$LABEL"
    mkdir -p "$DIR"

    if [ ! -f "$DIR/${NAME}_js/${NAME}.wasm" ]; then
        $CIRCOM "$CIRCUIT" --wasm -o "$DIR" >/dev/null 2>&1
    fi

    echo "$INPUT_JSON" > "$DIR/input.json"
    node "$DIR/${NAME}_js/generate_witness.js" \
         "$DIR/${NAME}_js/${NAME}.wasm" \
         "$DIR/input.json" \
         "$DIR/witness.wtns" >/dev/null 2>&1

    snarkjs wtns export json "$DIR/witness.wtns" "$DIR/witness.json" >/dev/null 2>&1
    node -p "require('$DIR/witness.json')[1]"
}

# Run a Solidity expression via a temporary forge test, return the numeric result
solidity_output() {
    local SOL_CALL=$1
    local TMP="$REPO_ROOT/test/_CrossCheckTmp.t.sol"
    cat > "$TMP" << SOLEOF
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
    local OUT
    OUT=$(forge test --match-test test_crosscheck --match-contract CrossCheckTmp -vv 2>&1 \
        | grep "XCHECK:" | awk '{print $NF}')
    rm -f "$TMP"
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
forge build --quiet 2>/dev/null

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

echo ""
echo "============================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================"

# Clean up
rm -f "$REPO_ROOT/test/_CrossCheckTmp.t.sol"

[ "$FAIL" -eq 0 ] || exit 1
