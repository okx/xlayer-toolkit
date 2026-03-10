#!/bin/bash
# Controlled benchmark runner — ensures consistent conditions across runs.
#
# Runs sudo purge + cooldown before each iteration to normalize macOS memory state,
# then reports median Peak Memory across all runs.
#
# Usage:
#   ./bench.sh [options] -- <command>
#
# Options:
#   --iterations N   Number of runs (default: 5)
#   --cooldown N     Seconds to wait after purge (default: 5)
#   --no-purge       Skip sudo purge between runs
#
# Examples:
#   ./bench.sh -- N=32768 MODE=prove PROOF_MODE=compressed ./sp1/fibonacci/run.sh run
#   ./bench.sh --iterations 3 -- N=20 MODE=prove ./risc0/fibonacci/run.sh run
#   ./bench.sh --no-purge --cooldown 10 -- N=20 MODE=prove ./jolt/fibonacci/run.sh run

set -euo pipefail

ITERATIONS=5
COOLDOWN=5
PURGE=true

# Parse options
while [[ $# -gt 0 ]]; do
    case $1 in
        --iterations) ITERATIONS=$2; shift 2 ;;
        --cooldown)   COOLDOWN=$2;   shift 2 ;;
        --no-purge)   PURGE=false;   shift   ;;
        --)           shift; break           ;;
        *)            break                  ;;
    esac
done

if [[ $# -eq 0 ]]; then
    echo "Error: no benchmark command specified"
    echo "Usage: $0 [options] -- <command>"
    exit 1
fi

# Separate env vars from the command
ENV_VARS=()
CMD=()
for arg in "$@"; do
    if [[ -z "${CMD[*]:-}" && "$arg" == *=* && ! "$arg" == */* ]]; then
        ENV_VARS+=("$arg")
    else
        CMD+=("$arg")
    fi
done

echo "=== Benchmark Runner ==="
echo "Iterations: $ITERATIONS"
echo "Cooldown:   ${COOLDOWN}s"
echo "Purge:      $PURGE"
echo "Command:    ${ENV_VARS[*]:-} ${CMD[*]}"
echo ""

# Collect metrics from each run
MEMORIES=()
PROVE_TIMES=()
PEAK_CPUS=()

for i in $(seq 1 "$ITERATIONS"); do
    echo "--- Run $i/$ITERATIONS ---"

    if $PURGE; then
        echo "Purging memory cache..."
        sudo purge 2>/dev/null || echo "Warning: purge failed (need sudo)"
        sleep "$COOLDOWN"
    elif [[ $i -gt 1 ]]; then
        sleep "$COOLDOWN"
    fi

    # Run the benchmark, capture output
    OUTPUT=$(env "${ENV_VARS[@]}" "${CMD[@]}" 2>&1) || true

    # Show the output
    echo "$OUTPUT"

    # Extract Peak Memory (matches "Peak Memory:  1234.5 MB")
    PEAK_MEM=$(echo "$OUTPUT" | grep -o 'Peak Memory: *[0-9.]*' | grep -o '[0-9.]*$' || echo "")
    PROVE_TIME=$(echo "$OUTPUT" | grep -o 'Prove Time: *[0-9.]*' | grep -o '[0-9.]*$' || echo "")
    PEAK_CPU=$(echo "$OUTPUT" | grep -o 'Peak CPU: *[0-9.]*' | grep -o '[0-9.]*$' || echo "")

    if [[ -n "$PEAK_MEM" ]]; then
        MEMORIES+=("$PEAK_MEM")
        echo "  -> Peak Memory: ${PEAK_MEM} MB"
    else
        echo "  -> Warning: could not parse Peak Memory from output"
    fi

    if [[ -n "$PROVE_TIME" ]]; then
        PROVE_TIMES+=("$PROVE_TIME")
    fi

    if [[ -n "$PEAK_CPU" ]]; then
        PEAK_CPUS+=("$PEAK_CPU")
    fi

    echo ""
done

# Compute median
median() {
    local sorted=($(printf '%s\n' "$@" | sort -g))
    local n=${#sorted[@]}
    if [[ $n -eq 0 ]]; then
        echo "N/A"
        return
    fi
    local mid=$((n / 2))
    if (( n % 2 == 1 )); then
        echo "${sorted[$mid]}"
    else
        # Average of two middle values
        echo "${sorted[$mid-1]} ${sorted[$mid]}" | awk '{printf "%.1f", ($1+$2)/2}'
    fi
}

echo "=== Results ($ITERATIONS runs) ==="
echo ""

if [[ ${#MEMORIES[@]} -gt 0 ]]; then
    echo "Peak Memory (MB):"
    for i in "${!MEMORIES[@]}"; do
        echo "  Run $((i+1)): ${MEMORIES[$i]}"
    done
    MEM_MEDIAN=$(median "${MEMORIES[@]}")
    echo "  Median:  $MEM_MEDIAN MB"
    echo ""
fi

if [[ ${#PROVE_TIMES[@]} -gt 0 ]]; then
    echo "Prove Time (s):"
    for i in "${!PROVE_TIMES[@]}"; do
        echo "  Run $((i+1)): ${PROVE_TIMES[$i]}"
    done
    TIME_MEDIAN=$(median "${PROVE_TIMES[@]}")
    echo "  Median:  ${TIME_MEDIAN}s"
    echo ""
fi

if [[ ${#PEAK_CPUS[@]} -gt 0 ]]; then
    echo "Peak CPU (%):"
    for i in "${!PEAK_CPUS[@]}"; do
        echo "  Run $((i+1)): ${PEAK_CPUS[$i]}"
    done
    CPU_MEDIAN=$(median "${PEAK_CPUS[@]}")
    echo "  Median:  ${CPU_MEDIAN}%"
    echo ""
fi
