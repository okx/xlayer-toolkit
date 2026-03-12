#!/bin/bash
# Matrix benchmark — run all combinations of N, proof mode, and prover.
#
# Usage:
#   ./matrix.sh                    # run all combinations with defaults
#   ./matrix.sh --dry-run          # print commands without executing
#   ./matrix.sh --n "20 1000"      # custom N values
#   ./matrix.sh --modes "core"     # only test core mode
#   ./matrix.sh --provers "cpu"    # CPU only (no GPU)
#   ./matrix.sh --output results.csv  # save results to CSV
#
# Environment:
#   ITERATIONS=1   Number of iterations per combination (passed to bench.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Defaults
N_VALUES=(20 1000 10000 100000)
MODES=(core compressed groth16)
PROVERS=(cpu cuda)
DRY_RUN=false
OUTPUT_CSV=""
ITERATIONS=${ITERATIONS:-1}
EXTRA_ARGS=""

# Parse options
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)    DRY_RUN=true; shift ;;
        --n)          IFS=' ' read -ra N_VALUES <<< "$2"; shift 2 ;;
        --modes)      IFS=' ' read -ra MODES <<< "$2"; shift 2 ;;
        --provers)    IFS=' ' read -ra PROVERS <<< "$2"; shift 2 ;;
        --output)     OUTPUT_CSV="$2"; shift 2 ;;
        --iterations) ITERATIONS="$2"; shift 2 ;;
        *)            echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "=== SP1 Fibonacci Matrix Benchmark ==="
echo "N values:   ${N_VALUES[*]}"
echo "Modes:      ${MODES[*]}"
echo "Provers:    ${PROVERS[*]}"
echo "Iterations: $ITERATIONS"
echo ""

# Verify binaries exist
for prover in "${PROVERS[@]}"; do
    if [ "$prover" = "cuda" ]; then
        BIN="$SCRIPT_DIR/target/release/fibonacci-gpu"
    else
        BIN="$SCRIPT_DIR/target/release/fibonacci-cpu"
    fi
    if [ ! -f "$BIN" ] && [ "$DRY_RUN" = false ]; then
        echo "Error: $BIN not found. Run './run.sh build' first." >&2
        exit 1
    fi
done

# CSV header
if [ -n "$OUTPUT_CSV" ]; then
    echo "n,mode,prover,prove_time_s,peak_memory_mb,peak_cpu_pct,cycle_count,proof_size_bytes" > "$OUTPUT_CSV"
    echo "Results will be saved to: $OUTPUT_CSV"
fi

TOTAL=$(( ${#N_VALUES[@]} * ${#MODES[@]} * ${#PROVERS[@]} ))
CURRENT=0
FAILED=0

for n in "${N_VALUES[@]}"; do
    for mode in "${MODES[@]}"; do
        for prover in "${PROVERS[@]}"; do
            CURRENT=$((CURRENT + 1))
            LABEL="[$CURRENT/$TOTAL] N=$n mode=$mode prover=$prover"

            # Skip groth16 on CPU if no gnark params downloaded
            # (will fail gracefully anyway, but this saves time)

            echo ""
            echo "============================================"
            echo "$LABEL"
            echo "============================================"

            CMD="N=$n MODE=prove PROOF_MODE=$mode SP1_PROVER=$prover $SCRIPT_DIR/run.sh run"

            if [ "$DRY_RUN" = true ]; then
                echo "  [dry-run] $CMD"
                continue
            fi

            # Run benchmark (use bench.sh for multiple iterations)
            set +e
            if [ "$ITERATIONS" -gt 1 ]; then
                OUTPUT=$("$BENCH_DIR/bench.sh" \
                    --iterations "$ITERATIONS" \
                    --no-purge \
                    -- \
                    N="$n" MODE=prove PROOF_MODE="$mode" SP1_PROVER="$prover" \
                    "$SCRIPT_DIR/run.sh" run 2>&1)
            else
                OUTPUT=$(N="$n" MODE=prove PROOF_MODE="$mode" SP1_PROVER="$prover" \
                    "$SCRIPT_DIR/run.sh" run 2>&1)
            fi
            EXIT_CODE=$?
            set -e

            echo "$OUTPUT"

            if [ $EXIT_CODE -ne 0 ]; then
                echo "  *** FAILED (exit code $EXIT_CODE) ***"
                FAILED=$((FAILED + 1))
                if [ -n "$OUTPUT_CSV" ]; then
                    echo "$n,$mode,$prover,FAIL,FAIL,FAIL,FAIL,FAIL" >> "$OUTPUT_CSV"
                fi
                continue
            fi

            # Parse metrics from output
            PROVE_TIME=$(echo "$OUTPUT" | grep -o 'Prove Time: *[0-9.]*' | grep -o '[0-9.]*$' || echo "")
            PEAK_MEM=$(echo "$OUTPUT" | grep -o 'Peak Memory: *[0-9.]*' | grep -o '[0-9.]*$' || echo "")
            PEAK_CPU=$(echo "$OUTPUT" | grep -o 'Peak CPU: *[0-9.]*' | grep -o '[0-9.]*$' || echo "")
            CYCLES=$(echo "$OUTPUT" | grep -o 'Cycle Count: *[0-9]*' | grep -o '[0-9]*$' || echo "")
            PROOF_SIZE=$(echo "$OUTPUT" | grep -o 'Proof Size: *[0-9]*' | grep -o '[0-9]*$' || echo "")

            # For bench.sh multi-iteration, use median values
            if [ "$ITERATIONS" -gt 1 ]; then
                MEDIAN_TIME=$(echo "$OUTPUT" | grep -A1 'Prove Time' | grep 'Median' | grep -o '[0-9.]*' || echo "$PROVE_TIME")
                MEDIAN_MEM=$(echo "$OUTPUT" | grep -A1 'Peak Memory' | grep 'Median' | grep -o '[0-9.]*' || echo "$PEAK_MEM")
                PROVE_TIME="${MEDIAN_TIME:-$PROVE_TIME}"
                PEAK_MEM="${MEDIAN_MEM:-$PEAK_MEM}"
            fi

            echo ""
            echo "  -> Prove: ${PROVE_TIME:-N/A}s | Memory: ${PEAK_MEM:-N/A} MB | CPU: ${PEAK_CPU:-N/A}%"

            if [ -n "$OUTPUT_CSV" ]; then
                echo "$n,$mode,$prover,${PROVE_TIME:-},${PEAK_MEM:-},${PEAK_CPU:-},${CYCLES:-},${PROOF_SIZE:-}" >> "$OUTPUT_CSV"
            fi
        done
    done
done

echo ""
echo "============================================"
echo "=== Matrix Complete: $CURRENT tests, $FAILED failed ==="
echo "============================================"

if [ -n "$OUTPUT_CSV" ]; then
    echo ""
    echo "Results saved to: $OUTPUT_CSV"
    echo ""
    column -t -s',' "$OUTPUT_CSV" 2>/dev/null || cat "$OUTPUT_CSV"
fi
