#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
bash "$REPO_ROOT/scripts/setup-libs.sh"

cd "$SCRIPT_DIR/.."
CIRCOM=~/.cargo/bin/circom
PTAU="pot12.ptau"

# Compile + measure constraints + prove. The r1cs / zkey guards make re-runs
# essentially free for unchanged circuits; we only keep stdout silent so the
# bench table stays clean — stderr passes through so failures are visible.
bench() {
    local LABEL=$1 CIRCUIT=$2 DIR=$3 INPUT=$4
    local NAME=$(basename "$CIRCUIT" .circom)

    mkdir -p "$DIR"
    if [ ! -f "${DIR}/${NAME}.r1cs" ]; then
        $CIRCOM "$CIRCUIT" --r1cs --wasm -o "$DIR" >/dev/null
    fi

    local CONSTRAINTS=$(snarkjs ri "${DIR}/${NAME}.r1cs" 2>&1 | grep "Constraints" | awk '{print $NF}')

    if [ ! -f "${DIR}/${NAME}.zkey" ]; then
        snarkjs groth16 setup "${DIR}/${NAME}.r1cs" "$PTAU" "${DIR}/${NAME}.zkey" >/dev/null
        snarkjs zkey export verificationkey "${DIR}/${NAME}.zkey" "${DIR}/vkey.json" >/dev/null
    fi
    node "${DIR}/${NAME}_js/generate_witness.js" "${DIR}/${NAME}_js/${NAME}.wasm" "$INPUT" "${DIR}/witness.wtns" >/dev/null

    local TOTAL=0
    for i in 1 2 3; do
        local T=$( { /usr/bin/time -p snarkjs groth16 prove \
            "${DIR}/${NAME}.zkey" "${DIR}/witness.wtns" \
            "${DIR}/proof.json" "${DIR}/public.json" ; } 2>&1 | grep "^real" | awk '{print $2}')
        TOTAL=$(echo "$TOTAL + $T" | bc)
    done
    local AVG=$(echo "scale=3; $TOTAL / 3" | bc)

    printf "  %-30s %6s constraints  %6ss prove\n" "$LABEL" "$CONSTRAINTS" "$AVG"
}

# Input files
mk_input() {
    local N=$1 FILE=$2
    local ARGS=""
    for i in $(seq 0 $((N-1))); do
        [ -n "$ARGS" ] && ARGS="${ARGS}, "
        ARGS="${ARGS}\"a${i}\": \"$((i+1))\""
    done
    echo "{${ARGS}}" > "$FILE"
}

# Special inputs for circuits with "inputs" array
mk_input_arr() {
    local N=$1 FILE=$2
    local ARGS=""
    for i in $(seq 1 $N); do
        [ -n "$ARGS" ] && ARGS="${ARGS}, "
        ARGS="${ARGS}\"$i\""
    done
    echo "{\"inputs\": [${ARGS}]}" > "$FILE"
}

# Special for left/right style
echo '{"left": "1", "right": "2"}' > /tmp/ci_lr.json
echo '{"left": "1", "right": "2", "third": "3"}' > /tmp/ci_lrt.json

mk_input 1 /tmp/ci_1.json
mk_input 2 /tmp/ci_2.json
mk_input 3 /tmp/ci_3.json
mk_input 4 /tmp/ci_4.json
mk_input 5 /tmp/ci_5.json
mk_input 6 /tmp/ci_6.json
mk_input 7 /tmp/ci_7.json
mk_input_arr 1 /tmp/ci_arr1.json
mk_input_arr 2 /tmp/ci_arr2.json
mk_input_arr 3 /tmp/ci_arr3.json
mk_input_arr 4 /tmp/ci_arr4.json
mk_input_arr 5 /tmp/ci_arr5.json
mk_input_arr 6 /tmp/ci_arr6.json
mk_input_arr 7 /tmp/ci_arr7.json
mk_input_arr 8 /tmp/ci_arr8.json
mk_input_arr 9 /tmp/ci_arr9.json

echo ""
echo "============================================"
echo "  Circom Full Benchmark"
echo "============================================"

echo ""
echo "--- 1 input ---"
bench "P1-circomlib(t=2)"            "circuits/bench_poseidon1_hash1.circom"      "build_full/p1_h1"       "/tmp/ci_arr1.json"
bench "P2-T2 hash1"        "circuits/bench_t2_hash1.circom"   "build_full/p2t2_h1"     "/tmp/ci_1.json"
bench "P2-T4S hash1"       "circuits/bench_opt_hash1.circom"  "build_full/p2t4s_h1"    "/tmp/ci_arr1.json"

echo ""
echo "--- 2 inputs ---"
bench "P1-circomlib(t=3)"            "circuits/bench_poseidon1_hash2.circom"      "build_full/p1_h2"       "/tmp/ci_arr2.json"
bench "P2-T2FF compress"   "circuits/bench_t2ff_compress.circom" "build_full/p2t2ff"    "/tmp/ci_2.json"
bench "P2-T3 hash2"        "circuits/bench_t3_hash2.circom"   "build_full/p2t3_h2"     "/tmp/ci_2.json"
bench "P2-T4S hash2"       "circuits/bench_opt_hash2.circom"  "build_full/p2t4s_h2"    "/tmp/ci_arr2.json"
bench "P2-NethermindEth compress"     "circuits/bench_compress.circom"             "build_full/nm_comp"     "/tmp/ci_lr.json"
bench "P2-NethermindEth hash2"        "circuits/bench_hash2.circom"               "build_full/nm_h2"       "/tmp/ci_lr.json"
bench "P2-Worldcoin t=2"          "circuits/bench_worldcoin_t2.circom"        "build_full/wc_t2"       "/tmp/ci_lr.json"
bench "P2-Worldcoin t=3"          "circuits/bench_worldcoin_t3.circom"        "build_full/wc_t3"       "/tmp/ci_lr.json"
bench "P2-bkomuves t=3"          "circuits/bench_bk_t3_compress.circom"     "build_full/bk_t3"       "/tmp/ci_lr.json"

echo ""
echo "--- 3 inputs ---"
bench "P1-circomlib(t=4)"            "circuits/bench_poseidon1_hash3.circom"      "build_full/p1_h3"       "/tmp/ci_arr3.json"
bench "P2-T4 hash3"        "circuits/bench_t4_hash3.circom"   "build_full/p2t4_h3"     "/tmp/ci_3.json"
bench "P2-T4S hash3"       "circuits/bench_opt_hash3.circom"  "build_full/p2t4s_h3"    "/tmp/ci_arr3.json"
bench "P2-NethermindEth t=4"          "circuits/bench_nm_t4_perm.circom"          "build_full/nm_t4"       "/tmp/ci_lrt.json"
bench "P2-Worldcoin t=4"          "circuits/bench_worldcoin_t4.circom"        "build_full/wc_t4"       "/tmp/ci_lrt.json"

echo ""
echo "--- 4 inputs ---"
bench "P1-circomlib(t=5)"            "circuits/bench_poseidon1_hash4.circom"      "build_full/p1_h4"       "/tmp/ci_arr4.json"
bench "P2-T4S hash4"       "circuits/bench_opt_hash4.circom"  "build_full/p2t4s_h4"    "/tmp/ci_arr4.json"
bench "P2-T8 hash4(pad)"   "circuits/bench_t8_hash4_pad.circom" "build_full/p2t8_h4"   "/tmp/ci_4.json"
bench "P2-Worldcoin-t8 hash4(pad)" "circuits/bench_wc_t8_hash4_pad.circom" "build_full/wc_t8_h4" "/tmp/ci_4.json"

echo ""
echo "--- 5 inputs ---"
bench "P1-circomlib(t=6)"            "circuits/bench_poseidon1_hash5.circom"      "build_full/p1_h5"       "/tmp/ci_arr5.json"
bench "P2-T4S hash5"       "circuits/bench_opt_hash5.circom"  "build_full/p2t4s_h5"    "/tmp/ci_arr5.json"
bench "P2-T8 hash5(pad)"   "circuits/bench_t8_hash5_pad.circom" "build_full/p2t8_h5"   "/tmp/ci_5.json"
bench "P2-Worldcoin-t8 hash5(pad)" "circuits/bench_wc_t8_hash5_pad.circom"    "build_full/wc_t8_h5"    "/tmp/ci_5.json"

echo ""
echo "--- 6 inputs ---"
bench "P1-circomlib(t=7)"            "circuits/bench_poseidon1_hash6.circom"      "build_full/p1_h6"       "/tmp/ci_arr6.json"
bench "P2-T4S hash6"       "circuits/bench_opt_hash6.circom"  "build_full/p2t4s_h6"    "/tmp/ci_arr6.json"
bench "P2-T8 hash6(pad)"   "circuits/bench_t8_hash6_pad.circom" "build_full/p2t8_h6"   "/tmp/ci_6.json"
bench "P2-Worldcoin-t8 hash6(pad)" "circuits/bench_wc_t8_hash6_pad.circom"    "build_full/wc_t8_h6"    "/tmp/ci_6.json"

echo ""
echo "--- 7 inputs ---"
bench "P1-circomlib(t=8)"            "circuits/bench_poseidon1_hash7.circom"      "build_full/p1_h7"       "/tmp/ci_arr7.json"
bench "P2-T4S hash7"       "circuits/bench_opt_hash7.circom"  "build_full/p2t4s_h7"    "/tmp/ci_arr7.json"
bench "P2-T8 hash7"        "circuits/bench_t8_hash7.circom"   "build_full/p2t8_h7"     "/tmp/ci_7.json"
bench "P2-Worldcoin-t8 hash7(pad)" "circuits/bench_wc_t8_hash7_pad.circom"    "build_full/wc_t8_h7"    "/tmp/ci_7.json"

echo ""
echo "--- 8 inputs ---"
bench "P1-circomlib(t=9)"            "circuits/bench_poseidon1_hash8.circom"      "build_full/p1_h8"       "/tmp/ci_arr8.json"
bench "P2-T4S hash8"       "circuits/bench_opt_hash8.circom"  "build_full/p2t4s_h8"    "/tmp/ci_arr8.json"

echo ""
echo "--- 9 inputs ---"
bench "P1-circomlib(t=10)"           "circuits/bench_poseidon1_hash9.circom"      "build_full/p1_h9"       "/tmp/ci_arr9.json"
bench "P2-T4S hash9"       "circuits/bench_opt_hash9.circom"  "build_full/p2t4s_h9"    "/tmp/ci_arr9.json"
