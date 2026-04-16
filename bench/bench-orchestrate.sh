#!/usr/bin/env bash
# bench-orchestrate.sh — runs 200M + 500M sessions with per-CL failure handling
# Does NOT use set -e globally: a failed CL logs the error and the loop continues.
# bench.sh now exits non-zero on bench failure, so we detect it with || here.
set -uo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_DIR_BASE="$BENCH_DIR/runs"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
OK()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅  $*"; }
FAIL() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌  $*"; }

FAILED_RUNS=()

# run_one <cl> <gas> <workers> <session_ts>
run_one() {
    local cl="$1" gas="$2" workers="$3" ts="$4"
    log "--- Starting: $cl  gas=$gas  workers=$workers ---"
    if SESSION_TS="$ts" bash "$BENCH_DIR/bench.sh" "$cl" \
        --gas-limit "$gas" --duration 120 --workers "$workers" --sender adventure; then
        OK "$cl ($gas) complete"
    else
        local rc=$?
        FAIL "$cl ($gas) FAILED (bench.sh exit $rc) — continuing to next CL"
        FAILED_RUNS+=("$cl@$gas")
    fi
}

log "==================================================================="
log "=== BENCH ORCHESTRATOR STARTED"
log "=== Plan: 200M (20w) → 500M (40w), 4 CLs each"
log "==================================================================="

# ── 200M session ──────────────────────────────────────────────────────────────
log "=== 200M SESSION — 20 workers ==="
TS_200M=$(date +%Y%m%d_%H%M%S)
log "SESSION_TS=$TS_200M"

for CL in op-node kona-okx-baseline kona-okx-optimised base-cl; do
    run_one "$CL" 200M 20 "$TS_200M"
done

log "=== 200M DONE — results: $SESSION_DIR_BASE/adv-erc20-20w-120s-200Mgas-$TS_200M/"
[[ -f "$SESSION_DIR_BASE/adv-erc20-20w-120s-200Mgas-$TS_200M/comparison.md" ]] \
    && OK "comparison.md generated" \
    || FAIL "comparison.md missing — check which CLs produced JSON"

# ── 500M session ──────────────────────────────────────────────────────────────
log "=== 500M SESSION — 40 workers ==="
TS_500M=$(date +%Y%m%d_%H%M%S)
log "SESSION_TS=$TS_500M"

for CL in op-node kona-okx-baseline kona-okx-optimised base-cl; do
    run_one "$CL" 500M 40 "$TS_500M"
done

log "=== 500M DONE — results: $SESSION_DIR_BASE/adv-erc20-40w-120s-500Mgas-$TS_500M/"
[[ -f "$SESSION_DIR_BASE/adv-erc20-40w-120s-500Mgas-$TS_500M/comparison.md" ]] \
    && OK "comparison.md generated" \
    || FAIL "comparison.md missing — check which CLs produced JSON"

# ── Phase 3: retry any failed 200M CLs into the existing 200M session ─────────
# If any 200M CLs failed (e.g. kona-okx-baseline sequencer stuck), retry them
# once after 500M finishes. Drops JSON into the same TS_200M dir so comparison
# auto-regenerates with the full 4-CL picture.
if [[ ${#FAILED_RUNS[@]} -gt 0 ]]; then
    log "=== RETRY PHASE — retrying failed 200M CLs ==="
    STILL_FAILED=()
    for entry in "${FAILED_RUNS[@]}"; do
        cl="${entry%@*}"
        gas="${entry#*@}"
        [[ "$gas" != "200M" ]] && continue   # only retry 200M failures
        log "--- Retrying: $cl (200M, 20w, SESSION_TS=$TS_200M) ---"
        if SESSION_TS="$TS_200M" bash "$BENCH_DIR/bench.sh" "$cl" \
            --gas-limit 200M --duration 120 --workers 20 --sender adventure; then
            OK "$cl (200M) retry succeeded — comparison.md will regenerate"
        else
            FAIL "$cl (200M) retry also failed"
            STILL_FAILED+=("$cl@200M")
        fi
    done
    FAILED_RUNS=("${STILL_FAILED[@]+"${STILL_FAILED[@]}"}")
fi

# ── Final summary ─────────────────────────────────────────────────────────────
log "==================================================================="
if [[ ${#FAILED_RUNS[@]} -eq 0 ]]; then
    OK "ALL DONE — all CLs succeeded"
else
    FAIL "DONE WITH FAILURES — ${#FAILED_RUNS[@]} run(s) failed: ${FAILED_RUNS[*]}"
    FAIL "Partial results still usable. Check docker logs for root cause."
fi
log "==================================================================="
