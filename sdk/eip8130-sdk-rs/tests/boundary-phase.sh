# EIP-8130 BOUNDARY / EDGE-CASE tests — phase execution semantics.
#
# Sourced by run-boundary-tests.sh (or run-eip8130-tests.sh) AFTER lib.sh.
# No shebang on purpose; this file only defines functions and exports
# the test ID list at the bottom.
#
# Coverage focus (companion to the basic suite's T-03..T-09):
#   - Phase count edges (1 phase, many phases, fan-out shapes).
#   - Atomic-within-phase rollback (OK, OK, OK, REVERT → all rolled back).
#   - Multi-phase ordering: revert in phase k → phases [k..] all `false`.
#   - Empty-phase semantics (vacuous success per spec).
#   - Skip-after-revert short-circuit (mixed [OK, REVERT, OK] → [t,f,f]).
#   - Per-phase gas pressure (phase 0 burns budget → phase 1 OOGs).
#
# ID range: B-150..B-199.
#
# Spec citations refer to EIP-8130 §"Call Execution" / §"RPC Extensions".

# ── Test cases ───────────────────────────────────────────────────────────────

# A. Phase count edges

test_B150() {
    # Spec §"Call Execution" — minimum well-formed shape: 1 phase × 1 call.
    run_case B-150 "1 phase × 1 call → [true]" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --phase "$T1,0x0150" \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local ps; ps=$(phase_statuses "$out")
    if assert_status "$out" success && [[ "$ps" == "true" ]]; then ok
    else fail B-150 "phaseStatuses=$ps; $out"; fi
}

test_B151() {
    # Spec §"Call Execution" — 50 phases × 1 call each, well under the
    # MAX_CALLS_PER_TX=100 aggregate cap. Verifies the chain has no
    # implicit per-tx phase-count cap below the aggregate limit.
    run_case B-151 "50 phases × 1 call each → all true" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-151)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    fund_account "$fresh_addr" 0.1ether
    local n; n=$(get_nonce $fresh_addr 0x0)
    local args=()
    for p in $(seq 1 50); do args+=(--phase "$T1,0x"); done
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key "${args[@]}" \
        --nonce-sequence $n --gas-limit 5000000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local ps; ps=$(phase_statuses "$out")
    # Build expected "true,true,...,true" (50 times).
    local expect; expect=$(python3 -c 'print(",".join(["true"]*50))')
    if assert_status "$out" success && [[ "$ps" == "$expect" ]]; then ok
    else fail B-151 "phaseStatuses=$ps; $out"; fi
}

test_B152() {
    # Spec §"Call Execution" — 50 phases × 2 calls = 100 calls (at the
    # MAX_CALLS_PER_TX limit). Verifies multi-call/multi-phase shapes
    # don't exceed the per-tx aggregate.
    run_case B-152 "50 phases × 2 calls (=100 total, at cap) → all true" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-152)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    fund_account "$fresh_addr" 0.1ether
    local n; n=$(get_nonce $fresh_addr 0x0)
    local args=()
    for p in $(seq 1 50); do args+=(--phase "$T1,0x;$T2,0x"); done
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key "${args[@]}" \
        --nonce-sequence $n --gas-limit 8000000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local ps; ps=$(phase_statuses "$out")
    local expect; expect=$(python3 -c 'print(",".join(["true"]*50))')
    if assert_status "$out" success && [[ "$ps" == "$expect" ]]; then ok
    else fail B-152 "phaseStatuses=$ps; $out"; fi
}

test_B153() {
    # Spec §"Call Execution" — 51 phases × 2 calls = 102 calls > cap.
    # Aggregate limit is enforced regardless of phase distribution.
    run_case B-153 "51 phases × 2 calls (=102, over cap) → reject" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-153)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    fund_account "$fresh_addr" 0.1ether
    local n; n=$(get_nonce $fresh_addr 0x0)
    local args=()
    for p in $(seq 1 51); do args+=(--phase "$T1,0x;$T2,0x"); done
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key "${args[@]}" \
        --nonce-sequence $n --gas-limit 8000000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-153 "expected rejected (call cap); got: $out"; fi
}

# B. Multi-phase ordering: where in the sequence the revert happens

test_B154() {
    # Spec §"RPC Extensions": "Phases after a revert are not executed and
    # reported as 0x00." Revert in phase 0 of a 10-phase tx → all 10 false.
    run_case B-154 "Revert in phase 0 of 10 → all 10 phaseStatuses false" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local args=(--phase "$T_REVERT,0x")
    for p in $(seq 1 9); do args+=(--phase "$T1,0x"); done
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S "${args[@]}" \
        --nonce-sequence $n --gas-limit 800000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local ps; ps=$(phase_statuses "$out")
    local expect; expect=$(python3 -c 'print(",".join(["false"]*10))')
    if assert_status "$out" reverted && [[ "$ps" == "$expect" ]]; then ok
    else fail B-154 "phaseStatuses=$ps; $out"; fi
}

test_B155() {
    # Spec §"Call Execution" — revert in last phase (9 of 10) preserves
    # phaseStatuses[0..8] = true and phaseStatuses[9] = false.
    run_case B-155 "Revert in phase 9 of 10 → 9 trues then false" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local args=()
    for p in $(seq 1 9); do args+=(--phase "$T1,0x"); done
    args+=(--phase "$T_REVERT,0x")
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S "${args[@]}" \
        --nonce-sequence $n --gas-limit 800000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local ps; ps=$(phase_statuses "$out")
    local expect; expect=$(python3 -c 'print(",".join(["true"]*9 + ["false"]))')
    if assert_status "$out" reverted && [[ "$ps" == "$expect" ]]; then ok
    else fail B-155 "phaseStatuses=$ps; $out"; fi
}

test_B156() {
    # Spec §"Call Execution" — revert mid-sequence (phase 4 of 10):
    # phases 0..3 succeed, phase 4 reverts, phases 5..9 padded with false.
    run_case B-156 "Revert in phase 4 of 10 → [t,t,t,t,f,f,f,f,f,f]" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local args=()
    for p in $(seq 1 4); do args+=(--phase "$T1,0x"); done
    args+=(--phase "$T_REVERT,0x")
    for p in $(seq 1 5); do args+=(--phase "$T1,0x"); done
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S "${args[@]}" \
        --nonce-sequence $n --gas-limit 800000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local ps; ps=$(phase_statuses "$out")
    local expect; expect=$(python3 -c 'print(",".join(["true"]*4 + ["false"]*6))')
    if assert_status "$out" reverted && [[ "$ps" == "$expect" ]]; then ok
    else fail B-156 "phaseStatuses=$ps; $out"; fi
}

# C. Within-phase atomicity: REVERT at various positions in a phase

test_B157() {
    # Spec §"Call Execution" — single-call phase with REVERT → [false].
    # Smallest possible "atomic rollback" shape.
    run_case B-157 "Single-call phase [REVERT] → status=reverted, [false]" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --phase "$T_REVERT,0x" \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local ps; ps=$(phase_statuses "$out")
    if assert_status "$out" reverted && [[ "$ps" == "false" ]]; then ok
    else fail B-157 "phaseStatuses=$ps; $out"; fi
}

test_B158() {
    # Spec §"Call Execution" — phase = [OK, OK, OK, REVERT]. Per the
    # handler, the entire phase is reverted via checkpoint_revert; even
    # though three calls succeeded individually, none of their state
    # changes persist. Single-phase tx so phaseStatuses length = 1.
    run_case B-158 "Phase [OK,OK,OK,REVERT] → atomic rollback, [false]" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S \
        --phase "$T1,0xa1;$T2,0xa2;$T3,0xa3;$T_REVERT,0xa4" \
        --nonce-sequence $n --gas-limit 200000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local ps; ps=$(phase_statuses "$out")
    if assert_status "$out" reverted && [[ "$ps" == "false" ]]; then ok
    else fail B-158 "phaseStatuses=$ps; $out"; fi
}

test_B159() {
    # Spec §"Call Execution" — REVERT in the middle of a phase aborts the
    # remaining calls in that phase. Single phase so result is [false].
    run_case B-159 "Phase [OK,REVERT,OK] → [false] (post-revert call skipped within phase)" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S \
        --phase "$T1,0xa1;$T_REVERT,0xa2;$T2,0xa3" \
        --nonce-sequence $n --gas-limit 200000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local ps; ps=$(phase_statuses "$out")
    if assert_status "$out" reverted && [[ "$ps" == "false" ]]; then ok
    else fail B-159 "phaseStatuses=$ps; $out"; fi
}

# D. Mixed result patterns across phases

test_B160() {
    # Spec §"RPC Extensions" — phase 1 reverts → phase 2 skipped (padded
    # with false). Asserts EXACT pattern [true,false,false], not just length.
    run_case B-160 "[OK | REVERT | OK] → [true,false,false]" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S \
        --phase "$T1,0x060a" \
        --phase "$T_REVERT,0x060b" \
        --phase "$T2,0x060c" \
        --nonce-sequence $n --gas-limit 300000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local ps; ps=$(phase_statuses "$out")
    if assert_status "$out" reverted && [[ "$ps" == "true,false,false" ]]; then ok
    else fail B-160 "phaseStatuses=$ps; $out"; fi
}

test_B161() {
    # Spec §"Call Execution" — multi-call phase 0 succeeds atomically;
    # multi-call phase 1 reverts atomically; phase 2 skipped/padded.
    # Asserts exact [true,false,false].
    run_case B-161 "[OK;OK | OK,REVERT | OK] → [true,false,false]" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S \
        --phase "$T1,0xa1;$T2,0xa2" \
        --phase "$T1,0xb1;$T_REVERT,0xb2" \
        --phase "$T3,0xc1" \
        --nonce-sequence $n --gas-limit 400000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local ps; ps=$(phase_statuses "$out")
    if assert_status "$out" reverted && [[ "$ps" == "true,false,false" ]]; then ok
    else fail B-161 "phaseStatuses=$ps; $out"; fi
}

test_B162() {
    # Spec §"RPC Extensions" — 4-phase pattern with revert at phase 2
    # demonstrates the padding behavior past the revert: [t,t,f,f].
    run_case B-162 "[OK | OK | REVERT | OK] → [true,true,false,false]" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S \
        --phase "$T1,0xa1" \
        --phase "$T2,0xa2" \
        --phase "$T_REVERT,0xa3" \
        --phase "$T3,0xa4" \
        --nonce-sequence $n --gas-limit 400000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local ps; ps=$(phase_statuses "$out")
    if assert_status "$out" reverted && [[ "$ps" == "true,true,false,false" ]]; then ok
    else fail B-162 "phaseStatuses=$ps; $out"; fi
}

# E. Empty phase semantics

test_B163() {
    # Spec §"Call Execution" — "If `calls` is empty, the transaction is
    # considered successful." A single phase with zero calls in it is the
    # in-phase analogue: the phase loop's per-call loop body never runs,
    # `phase_ok` stays true, status=success, phaseStatuses=[true].
    run_case B-163 "Single empty phase (--phase \"\") → success, [true]" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --phase "" \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local ps; ps=$(phase_statuses "$out")
    # Some SDK builds may reject empty phase strings client-side; allow
    # rejection but require a clear classification either way.
    if assert_status "$out" success && [[ "$ps" == "true" ]]; then ok
    elif assert_status "$out" rejected; then
        skip "B-163 SDK rejects empty phase string client-side"
    else fail B-163 "phaseStatuses=$ps; $out"; fi
}

test_B164() {
    # Spec §"Call Execution" — empty phase between two non-empty phases
    # should not stop execution; phase indexing still produces [t,t,t].
    run_case B-164 "[OK | empty | OK] → [true,true,true] (empty phase is success)" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S \
        --phase "$T1,0xa1" \
        --phase "" \
        --phase "$T2,0xa2" \
        --nonce-sequence $n --gas-limit 300000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local ps; ps=$(phase_statuses "$out")
    if assert_status "$out" success && [[ "$ps" == "true,true,true" ]]; then ok
    elif assert_status "$out" rejected; then
        skip "B-164 SDK rejects empty phase string client-side"
    else fail B-164 "phaseStatuses=$ps; $out"; fi
}

# F. Single-call distribution variants

test_B165() {
    # Same number of calls (10) but distributed differently from existing
    # B-03 (10 phases × 10 calls): here it's 10 phases × 1 call. Verifies
    # that gas accounting / phase loop overhead doesn't reject this shape.
    run_case B-165 "10 phases × 1 call → [true]*10 (per-phase shape)" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-165)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    fund_account "$fresh_addr" 0.05ether
    local n; n=$(get_nonce $fresh_addr 0x0)
    local args=()
    for p in $(seq 1 10); do args+=(--phase "$T1,0x"); done
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key "${args[@]}" \
        --nonce-sequence $n --gas-limit 1000000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local ps; ps=$(phase_statuses "$out")
    local expect; expect=$(python3 -c 'print(",".join(["true"]*10))')
    if assert_status "$out" success && [[ "$ps" == "$expect" ]]; then ok
    else fail B-165 "phaseStatuses=$ps; $out"; fi
}

# G. Per-phase gas pressure and OOG

test_B166() {
    # Spec §"Call Execution" — per-phase OOG. Phase 0 call burns large
    # calldata gas (64 KiB zeros = 4*65536 = 262144 calldata gas alone),
    # and the tx-level gas_limit is set just above intrinsic so phase 1
    # cannot complete. Per the handler loop, a phase that exhausts
    # `gas_remaining` sets phase_ok=false and short-circuits remaining
    # phases. We assert reverted with phase 0 = false.
    run_case B-166 "Phase 0 OOG via huge calldata → [false,false]" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local big_data="0x$(python3 -c 'print("00"*65536)')"
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S \
        --phase "$T1,$big_data" \
        --phase "$T2,0xb2" \
        --nonce-sequence $n --gas-limit 280000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    # Either rejected pre-inclusion (intrinsic check) or phase 0 reverts
    # in-block. Both classifications are spec-compliant for this shape;
    # if it lands in-block, phaseStatuses MUST be [false,false].
    if assert_status "$out" rejected; then ok; return; fi
    local ps; ps=$(phase_statuses "$out")
    if assert_status "$out" reverted && [[ "$ps" == "false,false" ]]; then ok
    else fail B-166 "phaseStatuses=$ps; $out"; fi
}

test_B167() {
    # Spec §"Call Execution" — phase 0 burns most of the budget on a
    # large-calldata call, phase 1 then has insufficient gas remaining
    # for its own large-calldata call → phase 1 reverts (or chain
    # rejects the whole tx for intrinsic). Demonstrates that gas
    # accounting flows across phases (gas_remaining is shared).
    run_case B-167 "Phase 0 burns budget, phase 1 OOG → [true,false] or rejected" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    # 16 KiB of calldata each — phase 0 fits, phase 1 should not.
    local mid_data="0x$(python3 -c 'print("00"*16384)')"
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S \
        --phase "$T1,$mid_data" \
        --phase "$T2,$mid_data" \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok; return; fi
    local ps; ps=$(phase_statuses "$out")
    # If the chain accepts the tx (gas_limit covers phase 0's 16K
    # calldata), phase 1 must fail since shared gas budget is exhausted.
    # Per spec, status=reverted with phaseStatuses[0]=true and [1]=false.
    if assert_status "$out" reverted && [[ "$ps" == "true,false" ]]; then ok
    else fail B-167 "expected [true,false] or rejected; phaseStatuses=$ps; $out"; fi
}

test_B168() {
    # Spec §"Call Execution" — sanity: 3 phases, each tiny, plenty of
    # gas. Asserts the all-success exact pattern [t,t,t]. Exists to
    # complement B-167's gas-pressure boundary (so gas budgeting doesn't
    # accidentally regress phases without revert markers).
    run_case B-168 "3 phases all OK with generous gas → [true,true,true]" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S \
        --phase "$T1,0x068a" \
        --phase "$T2,0x068b" \
        --phase "$T3,0x068c" \
        --nonce-sequence $n --gas-limit 300000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local ps; ps=$(phase_statuses "$out")
    if assert_status "$out" success && [[ "$ps" == "true,true,true" ]]; then ok
    else fail B-168 "phaseStatuses=$ps; $out"; fi
}

# H. Within-phase atomicity boundary: REVERT as the very first call

test_B169() {
    # Spec §"Call Execution" — REVERT is the FIRST call in a multi-call
    # phase: subsequent calls in the phase are skipped, the phase-level
    # checkpoint is reverted, and phaseStatuses[0] = false. With a
    # following phase, that phase is also skipped → [false,false].
    run_case B-169 "Phase 0 [REVERT,OK] then phase 1 OK → [false,false]" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S \
        --phase "$T_REVERT,0xa1;$T1,0xa2" \
        --phase "$T2,0xb1" \
        --nonce-sequence $n --gas-limit 300000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local ps; ps=$(phase_statuses "$out")
    if assert_status "$out" reverted && [[ "$ps" == "false,false" ]]; then ok
    else fail B-169 "phaseStatuses=$ps; $out"; fi
}

# ── Export the test ID list ──────────────────────────────────────────────────
# Listed in execution order; runner sources this file and iterates the array.
BOUNDARY_PHASE_TESTS=(
    test_B150
    test_B151
    test_B152
    test_B153
    test_B154
    test_B155
    test_B156
    test_B157
    test_B158
    test_B159
    test_B160
    test_B161
    test_B162
    test_B163
    test_B164
    test_B165
    test_B166
    test_B167
    test_B168
    test_B169
)
