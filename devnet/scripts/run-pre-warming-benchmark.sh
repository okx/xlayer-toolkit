#!/bin/bash
#===============================================================================
#  DEVNET PRE-WARMING BENCHMARK RUNNER (v2)
#===============================================================================
#
#  Runs pre-warming benchmarks with varying worker counts on devnet.
#  Uses scripts/devnet-comparison.sh for metric capture (with correct metric keys).
#
#  Improvements over v1:
#    - Updates BOTH pre-warming-workers AND pre-fetch-workers
#    - Configurable metrics host/port via env vars
#    - Configurable benchmark duration
#    - Auto-generates comparison reports at end
#    - Better logging and progress output
#
#  Metric Keys Used (via devnet-comparison.sh):
#    - reth_payloads_cached_reads_hits (always-on cache hits)
#    - reth_payloads_cached_reads_misses (always-on cache misses)
#    - reth_txpool_pre_warming_simulations_completed
#    - reth_txpool_pre_warming_prefetch_operations
#    - reth_txpool_pre_warming_prefetch_accounts
#    - reth_block_timing_build_exec_mempool_transactions_sum/count
#    - reth_block_timing_build_calc_state_root_sum/count
#
#  USAGE:
#    ./run-pre-warming-benchmark.sh
#
#  ENV VARS (optional):
#    METRICS_HOST=localhost        # Metrics endpoint host
#    METRICS_PORT=9001             # Metrics endpoint port
#    BENCHMARK_DURATION=3          # Duration in minutes per test
#    WORKERS="8 16 32 64"          # Worker counts to test
#
#===============================================================================

# set -e

# Configuration (can override via env vars)
WORKERS="${WORKERS:-8 16 32 64}"
METRICS_HOST="${METRICS_HOST:-localhost}"
METRICS_PORT="${METRICS_PORT:-9001}"
BENCHMARK_DURATION="${BENCHMARK_DURATION:-10}"  # minutes

wait_for_el_to_start() {
    CONTAINER_NAME=$1
    if [ -z "$CONTAINER_NAME" ]; then
        echo "Error: CONTAINER_NAME is not set"
        exit 1
    fi

    # Wait for execution layer to start
    echo "⏳ Waiting for execution layer to start in ${CONTAINER_NAME} ..."
    MAX_WAIT=300  # 5 minutes timeout
    ELAPSED=0
    FOUND=false

    while [ $ELAPSED -lt $MAX_WAIT ]; do
        if docker logs ${CONTAINER_NAME} 2>&1 | grep -q "Starting consensus engine"; then
            echo "✅ Execution layer started!"
            FOUND=true
            break
        fi
        sleep 2
        ELAPSED=$((ELAPSED + 2))
        if [ $((ELAPSED % 10)) -eq 0 ]; then
            echo "   Still waiting... (${ELAPSED}s/${MAX_WAIT}s)"
        fi
    done

    if [ "$FOUND" = false ]; then
        echo "❌ Error: Timeout waiting for execution layer to start (${MAX_WAIT}s)"
        exit 1
    fi
}

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

LOGS="pre-warm-logs-$(date +%Y%m%d_%H%M%S)"
mkdir -p $LOGS

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  DEVNET PRE-WARMING BENCHMARK (v2)"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  Worker counts to test: ${WORKERS}"
echo "  Metrics endpoint: ${METRICS_HOST}:${METRICS_PORT}"
echo "  Benchmark duration: ${BENCHMARK_DURATION} minutes per run"
echo "  Output directory: ${LOGS}"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

#-------------------------------------------------------------------------------
# PHASE 1: Baseline (pre-warming OFF)
#-------------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  PHASE 1: Running benchmark with pre-warming=false (baseline)"
echo "═══════════════════════════════════════════════════════════════════════════"

echo "🔄 Stopping op-seq and op-reth-seq..."
docker compose down op-seq op-reth-seq

sed_inplace "s/txpool.pre-warming=[a-z]*/txpool.pre-warming=false/" entrypoint/reth-seq.sh

echo "🚀 Starting op-reth-seq and op-seq..."
docker compose up -d op-reth-seq
wait_for_el_to_start "op-reth-seq"
docker compose up -d op-seq
sleep 30

echo "📊 Capturing metrics for ${BENCHMARK_DURATION} minutes..."
./scripts/devnet-comparison.sh ${METRICS_HOST} ${METRICS_PORT} ${BENCHMARK_DURATION} ${LOGS}/prewarming_metrics_no_prewarming.json &
timeout ${BENCHMARK_DURATION}m adventure native-bench -f ../tools/adventure/testdata/config.json --csv-report ${LOGS}/tps_no_prewarming.csv
wait

docker logs op-reth-seq | grep "Block added" > ${LOGS}/op-reth-seq-log_no_prewarming.txt 2>&1
echo "✅ Baseline capture complete"

# Enable pre-warming for next phases
sed_inplace "s/txpool.pre-warming=[a-z]*/txpool.pre-warming=true/" entrypoint/reth-seq.sh

#-------------------------------------------------------------------------------
# PHASE 2: Test with varying worker counts
#-------------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  PHASE 2: Running benchmark with pre-warming=true (varying workers)"
echo "═══════════════════════════════════════════════════════════════════════════"

for W in $WORKERS; do
    echo ""
    echo "───────────────────────────────────────────────────────────────────────────"
    echo "  Testing with ${W} workers (pre-warming + pre-fetch)"
    echo "───────────────────────────────────────────────────────────────────────────"

    echo "🔄 Stopping op-seq and op-reth-seq..."
    docker compose down op-seq op-reth-seq

    # Update BOTH pre-warming workers AND pre-fetch workers
    sed_inplace "s/txpool.pre-warming-workers=[0-9]*/txpool.pre-warming-workers=$W/" entrypoint/reth-seq.sh
    sed_inplace "s/txpool.pre-fetch-workers=[0-9]*/txpool.pre-fetch-workers=$W/" entrypoint/reth-seq.sh

    echo "🚀 Starting op-reth-seq and op-seq..."
    docker compose up -d op-reth-seq
    wait_for_el_to_start "op-reth-seq"
    docker compose up -d op-seq
    sleep 30

    echo "📊 Capturing metrics for ${BENCHMARK_DURATION} minutes with ${W} workers..."
    ./scripts/devnet-comparison.sh ${METRICS_HOST} ${METRICS_PORT} ${BENCHMARK_DURATION} ${LOGS}/prewarming_metrics_${W}_workers.json &
    timeout ${BENCHMARK_DURATION}m adventure native-bench -f ../tools/adventure/testdata/config.json --csv-report ${LOGS}/tps_${W}_workers.csv
    wait

    docker logs op-reth-seq | grep "Block added" > ${LOGS}/op-reth-seq-log_${W}_workers.txt 2>&1
    echo "✅ ${W} workers capture complete"
done

#-------------------------------------------------------------------------------
# PHASE 3: Generate comparison reports
#-------------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  PHASE 3: Generating Comparison Reports"
echo "═══════════════════════════════════════════════════════════════════════════"

BASELINE="${LOGS}/prewarming_metrics_no_prewarming.json"

for W in $WORKERS; do
    echo "  Comparing baseline vs ${W} workers..."
    ./scripts/devnet-comparison.sh --compare ${BASELINE} ${LOGS}/prewarming_metrics_${W}_workers.json > ${LOGS}/comparison_${W}_workers.txt 2>&1 || true
done

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  BENCHMARK COMPLETE"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo "  Results saved to: ${LOGS}/"
echo ""
echo "  Files generated:"
echo "    - prewarming_metrics_no_prewarming.json (baseline)"
for W in $WORKERS; do
    echo "    - prewarming_metrics_${W}_workers.json"
    echo "    - comparison_${W}_workers.txt"
    echo "    - tps_${W}_workers.csv"
done
echo ""
echo "  To view a comparison:"
echo "    cat ${LOGS}/comparison_<N>_workers.txt"
echo ""
echo "  Quick summary of all runs:"
echo "  ─────────────────────────────────────────────────────────────────────────"
printf "  %-20s %-15s %-15s %-15s\n" "Config" "Cache Hit %" "TPS" "Block Exec"
echo "  ─────────────────────────────────────────────────────────────────────────"

# Extract and display summary from JSON files
if [ -f "${BASELINE}" ]; then
    HIT_RATE=$(python3 -c "import json; f=open('${BASELINE}'); d=json.load(f); print(d.get('cache_hit_rate', 'N/A'))" 2>/dev/null || echo "N/A")
    TPS=$(python3 -c "import json; f=open('${BASELINE}'); d=json.load(f); print(d.get('avg_tps', 'N/A'))" 2>/dev/null || echo "N/A")
    BLOCK_EXEC=$(python3 -c "import json; f=open('${BASELINE}'); d=json.load(f); print(d.get('block_execution_ms', 'N/A'))" 2>/dev/null || echo "N/A")
    printf "  %-20s %-15s %-15s %-15s\n" "pre-warming=OFF" "${HIT_RATE}%" "${TPS}" "${BLOCK_EXEC}ms"
fi

for W in $WORKERS; do
    FILE="${LOGS}/prewarming_metrics_${W}_workers.json"
    if [ -f "${FILE}" ]; then
        HIT_RATE=$(python3 -c "import json; f=open('${FILE}'); d=json.load(f); print(d.get('cache_hit_rate', 'N/A'))" 2>/dev/null || echo "N/A")
        TPS=$(python3 -c "import json; f=open('${FILE}'); d=json.load(f); print(d.get('avg_tps', 'N/A'))" 2>/dev/null || echo "N/A")
        BLOCK_EXEC=$(python3 -c "import json; f=open('${FILE}'); d=json.load(f); print(d.get('block_execution_ms', 'N/A'))" 2>/dev/null || echo "N/A")
        printf "  %-20s %-15s %-15s %-15s\n" "${W} workers" "${HIT_RATE}%" "${TPS}" "${BLOCK_EXEC}ms"
    fi
done

echo "  ─────────────────────────────────────────────────────────────────────────"
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"

