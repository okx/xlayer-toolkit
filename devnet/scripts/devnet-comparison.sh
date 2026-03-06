#!/bin/bash
#===============================================================================
#  DEVNET/TESTNET PRE-WARMING COMPARISON SCRIPT
#===============================================================================
#
#  This script is designed for live devnet/testnet environments where:
#  - Node runs continuously (no restarts during test)
#  - Feature is enabled/disabled via deployment (not CLI flag)
#  - Metrics are captured over a time period
#
#  USAGE:
#    Phase 1: Deploy node WITHOUT pre-warming, run this script
#    Phase 2: Deploy node WITH pre-warming, run this script again
#    Phase 3: Compare the two result files
#
#  ./devnet_comparison.sh <METRICS_HOST> <METRICS_PORT> <DURATION_MINUTES> <OUTPUT_FILE>
#
#  Example:
#    ./devnet_comparison.sh 192.168.1.100 9001 30 results_prewarm_off.json
#    ./devnet_comparison.sh 192.168.1.100 9001 30 results_prewarm_on.json
#    ./devnet_comparison.sh --compare results_prewarm_off.json results_prewarm_on.json
#
#===============================================================================

# set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

#-------------------------------------------------------------------------------
# COMPARISON MODE
#-------------------------------------------------------------------------------
if [ "$1" = "--compare" ]; then
    FILE_OFF="$2"
    FILE_ON="$3"

    if [ ! -f "$FILE_OFF" ] || [ ! -f "$FILE_ON" ]; then
        echo -e "${RED}Error: Both result files must exist${NC}"
        echo "Usage: $0 --compare <results_off.json> <results_on.json>"
        exit 1
    fi

    echo ""
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  DEVNET PRE-WARMING COMPARISON REPORT${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    # Extract values from JSON files
    python3 << PYEOF
import json

with open("$FILE_OFF") as f:
    off = json.load(f)
with open("$FILE_ON") as f:
    on = json.load(f)

duration_off = off.get('duration_minutes', 'N/A')
duration_on = on.get('duration_minutes', 'N/A')
if duration_off != 'N/A' and duration_on != 'N/A':
    print(f"  Test Duration: {duration_off} minutes each")
print(f"  OFF Captured: {off['timestamp']}")
print(f"  ON Captured:  {on['timestamp']}")
print("")

# TPS Comparison
print("┌──────────────────────────────────────────────────────────────────────────────┐")
print("│  TRANSACTIONS PER SECOND (TPS)                                              │")
print("├──────────────────────────────────────────────────────────────────────────────┤")
tps_off = off.get('avg_tps', 0)
tps_on = on.get('avg_tps', 0)
tps_change = ((tps_on - tps_off) / tps_off * 100) if tps_off > 0 else 0
print(f"│  Pre-warming OFF:  {tps_off:>10.2f} TPS                                        │")
print(f"│  Pre-warming ON:   {tps_on:>10.2f} TPS                                        │")
print(f"│  Change:           {tps_change:>+10.1f}%                                         │")
print("└──────────────────────────────────────────────────────────────────────────────┘")
print("")

# Cache Hit Rate Comparison
print("┌──────────────────────────────────────────────────────────────────────────────┐")
print("│  CACHE HIT RATE                                                             │")
print("├──────────────────────────────────────────────────────────────────────────────┤")
hit_off = off.get('cache_hit_rate', 0)
hit_on = on.get('cache_hit_rate', 0)
hit_change = hit_on - hit_off
print(f"│  Pre-warming OFF:  {hit_off:>10.1f}%                                          │")
print(f"│  Pre-warming ON:   {hit_on:>10.1f}%                                          │")
print(f"│  Change:           {hit_change:>+10.1f}%                                          │")
print("└──────────────────────────────────────────────────────────────────────────────┘")
print("")

# Block Timing Comparison
print("┌──────────────────────────────────────────────────────────────────────────────┐")
print("│  BLOCK TIMING                                                               │")
print("├──────────────────────────────────────────────────────────────────────────────┤")
exec_off = off.get('block_execution_ms', 0)
exec_on = on.get('block_execution_ms', 0)
exec_change = ((exec_on - exec_off) / exec_off * 100) if exec_off > 0 else 0
# Format execution time - show in microseconds if very small
if exec_off < 0.01:
    exec_off_str = f"{exec_off * 1000:.2f} us"
else:
    exec_off_str = f"{exec_off:.4f} ms"
if exec_on < 0.01:
    exec_on_str = f"{exec_on * 1000:.2f} us"
else:
    exec_on_str = f"{exec_on:.4f} ms"
print(f"│  Block Execution (OFF):  {exec_off_str:>12}                                │")
print(f"│  Block Execution (ON):   {exec_on_str:>12}                                │")
print(f"│  Change:                 {exec_change:>+8.1f}%                                    │")
print("│                                                                              │")
state_off = off.get('state_root_ms', 0)
state_on = on.get('state_root_ms', 0)
state_change = ((state_on - state_off) / state_off * 100) if state_off > 0 else 0
print(f"│  State Root (OFF):       {state_off:>8.4f} ms                                 │")
print(f"│  State Root (ON):        {state_on:>8.4f} ms                                 │")
print(f"│  Change:                 {state_change:>+8.1f}%                                    │")
print("└──────────────────────────────────────────────────────────────────────────────┘")
print("")

# Pre-warming Stats (show if simulations or prefetch ops > 0)
sims = on.get('simulations_completed', 0)
prefetch = on.get('prefetch_ops', 0)
if sims > 0 or prefetch > 0:
    print("┌──────────────────────────────────────────────────────────────────────────────┐")
    print("│  PRE-WARMING STATISTICS (ON mode only)                                      │")
    print("├──────────────────────────────────────────────────────────────────────────────┤")
    print(f"│  Simulations Completed:  {sims:>10}                                   │")
    print(f"│  Simulations Failed:     {on.get('simulations_failed', 0):>10}                                   │")
    print(f"│  Prefetch Operations:    {prefetch:>10}                                   │")
    print(f"│  Accounts Prefetched:    {on.get('prefetch_accounts', 0):>10}                                   │")
    print(f"│  Storage Slots:          {on.get('prefetch_storage', 0):>10}                                   │")
    print("└──────────────────────────────────────────────────────────────────────────────┘")
    print("")

# Summary
print("══════════════════════════════════════════════════════════════════════════════")
print("  SUMMARY")
print("══════════════════════════════════════════════════════════════════════════════")
print("")
print(f"  Cache Hit Rate Change:    {hit_change:+.1f}%")
print(f"  TPS Change:               {tps_change:+.1f}%")
print(f"  Block Execution Change:   {exec_change:+.1f}%")
print(f"  State Root Change:        {state_change:+.1f}%")
print("")

# Key Findings
print("══════════════════════════════════════════════════════════════════════════════")
print("  KEY FINDINGS")
print("══════════════════════════════════════════════════════════════════════════════")
print("")

findings = []
warnings = []
recommendations = []

# Analyze Block Execution
if exec_change < -10:
    findings.append(f"Block execution is {abs(exec_change):.1f}% FASTER with pre-warming")
elif exec_change > 10:
    warnings.append(f"Block execution is {exec_change:.1f}% SLOWER with pre-warming - investigate overhead")
else:
    findings.append(f"Block execution similar ({exec_change:+.1f}%)")

# Analyze State Root
if state_change < -10:
    findings.append(f"State root calculation is {abs(state_change):.1f}% FASTER with pre-warming")
elif state_change > 10:
    warnings.append(f"State root calculation is {state_change:.1f}% SLOWER - unexpected")
else:
    findings.append(f"State root calculation similar ({state_change:+.1f}%)")

# Analyze Cache Hit Rate
if hit_on >= 95:
    findings.append(f"Excellent cache hit rate: {hit_on:.1f}%")
elif hit_on >= 80:
    findings.append(f"Good cache hit rate: {hit_on:.1f}%")
elif hit_on >= 60:
    warnings.append(f"Moderate cache hit rate: {hit_on:.1f}% - room for improvement")
else:
    warnings.append(f"Low cache hit rate: {hit_on:.1f}% - simulation may not be capturing all keys")

# Analyze Cache Hit Improvement
if hit_change > 10:
    findings.append(f"Cache hit rate improved by {hit_change:.1f}% with pre-warming")
elif hit_change < -5:
    warnings.append(f"Cache hit rate decreased by {abs(hit_change):.1f}% - unusual")

# Analyze Simulations
if sims > 0:
    findings.append(f"Pre-warming simulations working: {sims:,} completed")
    if on.get('simulations_failed', 0) > 0:
        fail_rate = on['simulations_failed'] * 100 / (sims + on['simulations_failed'])
        if fail_rate > 5:
            warnings.append(f"Simulation failure rate: {fail_rate:.1f}%")
else:
    if prefetch > 0:
        findings.append(f"Prefetch working without simulations (ETH transfers only)")
    else:
        warnings.append("No simulations completed - check if ERC20 transactions are being sent")

# Analyze Prefetch
if prefetch > 0:
    findings.append(f"Prefetch operations: {prefetch:,}")
    accounts = on.get('prefetch_accounts', 0)
    storage = on.get('prefetch_storage', 0)
    if storage > 0:
        findings.append(f"Storage slots prefetched: {storage:,} (ERC20 state)")
    if accounts > 0:
        findings.append(f"Accounts prefetched: {accounts:,}")
else:
    if sims > 0:
        warnings.append("Simulations completed but no prefetch operations - check prefetch logic")

# Analyze TPS
if tps_change > 5:
    findings.append(f"TPS improved by {tps_change:.1f}%")
elif tps_change < -5:
    warnings.append(f"TPS decreased by {abs(tps_change):.1f}% - overhead may be too high")

# Generate recommendations
if hit_on < 80:
    recommendations.append("Consider implementing full EVM simulation for better key discovery")
if sims == 0 and prefetch == 0:
    recommendations.append("Send ERC20 transactions (transfer, approve) to trigger simulation heuristics")
if exec_change > 0 and state_change < 0:
    recommendations.append("Pre-warming helps state root but adds execution overhead - acceptable trade-off")
if hit_on >= 90 and (exec_change < 0 or state_change < 0):
    recommendations.append("Pre-warming is effective - consider enabling in production")

# Print findings
print("  POSITIVE:")
for f in findings:
    print(f"    ✓ {f}")
print("")

if warnings:
    print("  WARNINGS:")
    for w in warnings:
        print(f"    ⚠ {w}")
    print("")

if recommendations:
    print("  RECOMMENDATIONS:")
    for r in recommendations:
        print(f"    → {r}")
    print("")

# Overall verdict
print("  VERDICT:")
score = 0
if exec_change < 0: score += 1
if state_change < 0: score += 1
if hit_on >= 80: score += 1
if sims > 0 or prefetch > 0: score += 1

if score >= 3:
    print("    ✓ Pre-warming is BENEFICIAL - recommend enabling")
elif score >= 2:
    print("    ~ Pre-warming shows MIXED results - test with higher load")
else:
    print("    ✗ Pre-warming needs OPTIMIZATION before production use")

print("")
print("══════════════════════════════════════════════════════════════════════════════")
PYEOF

    exit 0
fi

#-------------------------------------------------------------------------------
# CAPTURE MODE
#-------------------------------------------------------------------------------
METRICS_HOST="${1:-localhost}"
METRICS_PORT="${2:-9001}"
DURATION_MINUTES="${3:-10}"
OUTPUT_FILE="${4:-devnet_results_$(date +%Y%m%d_%H%M%S).json}"

METRICS_URL="http://${METRICS_HOST}:${METRICS_PORT}/metrics"
INTERVAL_SECONDS=30
ITERATIONS=$((DURATION_MINUTES * 60 / INTERVAL_SECONDS))

echo ""
echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  DEVNET METRICS CAPTURE${NC}"
echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Host:     ${METRICS_HOST}:${METRICS_PORT}"
echo -e "  Duration: ${DURATION_MINUTES} minutes"
echo -e "  Interval: ${INTERVAL_SECONDS} seconds"
echo -e "  Output:   ${OUTPUT_FILE}"
echo ""

# Verify connectivity
if ! curl -s "${METRICS_URL}" > /dev/null 2>&1; then
    echo -e "${RED}Error: Cannot connect to ${METRICS_URL}${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Connected to metrics endpoint${NC}"
echo ""

# Helper function to get metric value
get_metric() {
    local val=$(curl -s "${METRICS_URL}" 2>/dev/null | grep "^$1 " | awk '{print $2}' | head -1)
    # If not found with ^, try without (for metrics that might have different formatting)
    if [ -z "$val" ]; then
        val=$(curl -s "${METRICS_URL}" 2>/dev/null | grep "$1 " | grep -v "#" | awk '{print $2}' | head -1)
    fi
    echo "${val:-0}"
}

# Capture initial metrics
# Use ALWAYS-ON payloads_cached_reads_* metrics (tracked regardless of pre-warming)
# Plus pre-warming specific metrics (reth_txpool_pre_warming_*)
echo -e "${CYAN}Capturing initial metrics...${NC}"
# Always-on CachedReads metrics
INITIAL_CACHED_READS_HITS=$(get_metric "reth_payloads_cached_reads_hits")
INITIAL_CACHED_READS_MISSES=$(get_metric "reth_payloads_cached_reads_misses")
# Pre-warming specific metrics (will be 0 when pre-warming is OFF)
INITIAL_PREWARM_HITS=$(get_metric "reth_txpool_pre_warming_cache_hits")
INITIAL_PREWARM_MISSES=$(get_metric "reth_txpool_pre_warming_cache_misses")
INITIAL_SIMULATIONS=$(get_metric "reth_txpool_pre_warming_simulations_completed")
INITIAL_PREFETCH_OPS=$(get_metric "reth_txpool_pre_warming_prefetch_operations")

# Get block count for TPS calculation
INITIAL_BLOCK=$(curl -s "http://${METRICS_HOST}:8545" -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null | \
    python3 -c "import sys,json; print(int(json.load(sys.stdin).get('result','0x0'),16))" 2>/dev/null || echo "0")

INITIAL_TIME=$(date +%s)

echo -e "${CYAN}Monitoring for ${DURATION_MINUTES} minutes...${NC}"
echo ""

# Progress bar
for i in $(seq 1 $ITERATIONS); do
    sleep $INTERVAL_SECONDS
    PROGRESS=$((i * 100 / ITERATIONS))
    ELAPSED=$((i * INTERVAL_SECONDS / 60))
    printf "\r  [%-50s] %d%% (%d/%d min)" $(printf '#%.0s' $(seq 1 $((PROGRESS/2)))) $PROGRESS $ELAPSED $DURATION_MINUTES
done
echo ""
echo ""

# Capture final metrics
# Use ALWAYS-ON payloads_cached_reads_* metrics (tracked regardless of pre-warming)
echo -e "${CYAN}Capturing final metrics...${NC}"
# Always-on CachedReads metrics
FINAL_CACHED_READS_HITS=$(get_metric "reth_payloads_cached_reads_hits")
FINAL_CACHED_READS_MISSES=$(get_metric "reth_payloads_cached_reads_misses")
# Pre-warming specific metrics (will be 0 when pre-warming is OFF)
FINAL_PREWARM_HITS=$(get_metric "reth_txpool_pre_warming_cache_hits")
FINAL_PREWARM_MISSES=$(get_metric "reth_txpool_pre_warming_cache_misses")
FINAL_SIMULATIONS=$(get_metric "reth_txpool_pre_warming_simulations_completed")
FINAL_PREFETCH_OPS=$(get_metric "reth_txpool_pre_warming_prefetch_operations")
FINAL_PREFETCH_ACCOUNTS=$(get_metric "reth_txpool_pre_warming_prefetch_accounts")
FINAL_PREFETCH_STORAGE=$(get_metric "reth_txpool_pre_warming_prefetch_storage_slots")
FINAL_SIMULATIONS_FAILED=$(get_metric "reth_txpool_pre_warming_simulations_failed")

# Get block timing metrics (averages)
BUILD_EXEC_SUM=$(get_metric "reth_block_timing_build_exec_mempool_transactions_sum")
BUILD_EXEC_COUNT=$(get_metric "reth_block_timing_build_exec_mempool_transactions_count")
STATE_ROOT_SUM=$(get_metric "reth_block_timing_build_calc_state_root_sum")
STATE_ROOT_COUNT=$(get_metric "reth_block_timing_build_calc_state_root_count")

FINAL_BLOCK=$(curl -s "http://${METRICS_HOST}:8545" -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null | \
    python3 -c "import sys,json; print(int(json.load(sys.stdin).get('result','0x0'),16))" 2>/dev/null || echo "0")

FINAL_TIME=$(date +%s)

# Calculate deltas - use ALWAYS-ON CachedReads metrics for true baseline comparison
DELTA_HITS=$((FINAL_CACHED_READS_HITS - INITIAL_CACHED_READS_HITS))
DELTA_MISSES=$((FINAL_CACHED_READS_MISSES - INITIAL_CACHED_READS_MISSES))
TOTAL_ACCESS=$((DELTA_HITS + DELTA_MISSES))
DELTA_BLOCKS=$((FINAL_BLOCK - INITIAL_BLOCK))
DURATION_SECONDS=$((FINAL_TIME - INITIAL_TIME))

# Calculate rates
if [ $TOTAL_ACCESS -gt 0 ]; then
    HIT_RATE=$(python3 -c "print(round($DELTA_HITS * 100 / $TOTAL_ACCESS, 1))")
else
    HIT_RATE="0"
fi

if [ $DURATION_SECONDS -gt 0 ]; then
    # Approximate TPS from blocks (assuming ~50 txs per block on average)
    BLOCKS_PER_SEC=$(python3 -c "print(round($DELTA_BLOCKS / $DURATION_SECONDS, 4))")
    AVG_TPS=$(python3 -c "print(round($DELTA_BLOCKS * 50 / $DURATION_SECONDS, 2))")  # Rough estimate
else
    BLOCKS_PER_SEC="0"
    AVG_TPS="0"
fi

# Calculate block timing averages (in milliseconds, or microseconds if very small)
BUILD_EXEC_SUM="${BUILD_EXEC_SUM:-0}"
BUILD_EXEC_COUNT="${BUILD_EXEC_COUNT:-0}"
STATE_ROOT_SUM="${STATE_ROOT_SUM:-0}"
STATE_ROOT_COUNT="${STATE_ROOT_COUNT:-0}"

# Raw values in ms for JSON
BLOCK_EXEC_RAW_MS="0"
STATE_ROOT_RAW_MS="0"

if [ "$BUILD_EXEC_COUNT" != "0" ] && [ "$BUILD_EXEC_COUNT" != "" ]; then
    BLOCK_EXEC_RAW_MS=$(python3 -c "print(round(float('$BUILD_EXEC_SUM') / float('$BUILD_EXEC_COUNT') * 1000, 4))")
    BLOCK_EXEC_MS=$(python3 -c "
val = float('$BUILD_EXEC_SUM') / float('$BUILD_EXEC_COUNT') * 1000
if val < 0.01:
    print(f'{round(val * 1000, 2)} us')  # Show in microseconds
else:
    print(f'{round(val, 2)} ms')
")
else
    BLOCK_EXEC_MS="0 ms"
fi

if [ "$STATE_ROOT_COUNT" != "0" ] && [ "$STATE_ROOT_COUNT" != "" ]; then
    STATE_ROOT_RAW_MS=$(python3 -c "print(round(float('$STATE_ROOT_SUM') / float('$STATE_ROOT_COUNT') * 1000, 4))")
    STATE_ROOT_MS=$(python3 -c "
val = float('$STATE_ROOT_SUM') / float('$STATE_ROOT_COUNT') * 1000
if val < 0.01:
    print(f'{round(val * 1000, 2)} us')  # Show in microseconds
else:
    print(f'{round(val, 2)} ms')
")
else
    STATE_ROOT_MS="0 ms"
fi

# Pre-warming stats
DELTA_SIMULATIONS=$((FINAL_SIMULATIONS - INITIAL_SIMULATIONS))
DELTA_PREFETCH_OPS=$((FINAL_PREFETCH_OPS - INITIAL_PREFETCH_OPS))

# Print results
echo ""
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  CAPTURE RESULTS${NC}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Duration:           ${DURATION_MINUTES} minutes"
echo -e "  Blocks Processed:   ${DELTA_BLOCKS}"
echo -e "  Blocks/sec:         ${BLOCKS_PER_SEC}"
echo ""
echo -e "  ${BOLD}Cache Performance:${NC}"
echo -e "    Total Hits:       ${DELTA_HITS}"
echo -e "    Total Misses:     ${DELTA_MISSES}"
echo -e "    Hit Rate:         ${HIT_RATE}%"
echo ""
echo -e "  ${BOLD}Block Timing:${NC}"
echo -e "    Execution:        ${BLOCK_EXEC_MS}"
echo -e "    State Root:       ${STATE_ROOT_MS}"
echo ""

if [ "$DELTA_SIMULATIONS" -gt 0 ]; then
    echo -e "  ${BOLD}Pre-warming (detected):${NC}"
    echo -e "    Simulations:      ${DELTA_SIMULATIONS}"
    echo -e "    Prefetch Ops:     ${DELTA_PREFETCH_OPS}"
    echo ""
fi

# Save to JSON
python3 << PYEOF
import json
from datetime import datetime

results = {
    "timestamp": datetime.now().isoformat(),
    "host": "${METRICS_HOST}",
    "port": ${METRICS_PORT},
    "duration_minutes": ${DURATION_MINUTES},
    "duration_seconds": ${DURATION_SECONDS},
    "blocks_processed": ${DELTA_BLOCKS},
    "blocks_per_sec": ${BLOCKS_PER_SEC},
    "avg_tps": ${AVG_TPS},
    "cache_hits": ${DELTA_HITS},
    "cache_misses": ${DELTA_MISSES},
    "cache_hit_rate": ${HIT_RATE},
    "block_execution_ms": ${BLOCK_EXEC_RAW_MS},
    "state_root_ms": ${STATE_ROOT_RAW_MS},
    "simulations_completed": ${DELTA_SIMULATIONS:-0},
    "simulations_failed": ${FINAL_SIMULATIONS_FAILED:-0},
    "prefetch_ops": ${DELTA_PREFETCH_OPS:-0},
    "prefetch_accounts": ${FINAL_PREFETCH_ACCOUNTS:-0},
    "prefetch_storage": ${FINAL_PREFETCH_STORAGE:-0}
}

with open("${OUTPUT_FILE}", "w") as f:
    json.dump(results, f, indent=2)

print(f"Results saved to: ${OUTPUT_FILE}")
PYEOF

echo ""
echo -e "${GREEN}✅ Capture complete!${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Deploy node with opposite pre-warming setting"
echo -e "  2. Run this script again with a different output file"
echo -e "  3. Compare results:"
echo -e "     ${CYAN}$0 --compare results_off.json results_on.json${NC}"
echo ""

