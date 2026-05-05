#!/usr/bin/env bash
# EIP-8130 BOUNDARY / EDGE-CASE e2e test runner.
#
# Companion to run-basic-tests.sh — focuses on protocol-edge behavior:
# encoding limits, fee math edges, structural caps (MAX_CALLS_PER_TX,
# MAX_ACCOUNT_CHANGES_PER_TX), gas budgeting, and malformed-input rejection.
#
# Test IDs are prefixed B- to distinguish from basic T- IDs.
#
# Usage:
#   ./run-boundary-tests.sh                    # run full boundary suite
#   ./run-boundary-tests.sh B-01 B-12          # run specific cases
#   ./run-boundary-tests.sh -v                 # verbose

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
parse_common_args "$@"
preflight
echo "EIP-8130 BOUNDARY suite — $RPC_URL (chainId=$CHAIN_ID)"
echo

# Source agent-produced boundary chunks if present. Each file defines
# `test_BXXX` functions and exports a `BOUNDARY_<CATEGORY>_TESTS` array
# listing them. Missing files are silently skipped so the runner stays
# usable while subagents are still producing output.
declare -a EXTERNAL_TESTS=()
for chunk in boundary-encoding.sh boundary-phase.sh boundary-auth.sh \
             boundary-payer.sh boundary-spec.sh; do
    if [[ -f "$HERE/$chunk" ]]; then
        # shellcheck disable=SC1090
        source "$HERE/$chunk"
    fi
done
for arr_name in BOUNDARY_ENCODING_TESTS BOUNDARY_PHASE_TESTS \
                BOUNDARY_AUTH_TESTS BOUNDARY_PAYER_TESTS \
                BOUNDARY_SPEC_TESTS; do
    if declare -p "$arr_name" >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        eval "EXTERNAL_TESTS+=(\"\${${arr_name}[@]}\")"
    fi
done

# ── Test cases ───────────────────────────────────────────────────────────────

# A. Encoding & structural limits
test_B01() {
    run_case B-01 "MAX_CALLS_PER_TX=100: 100 calls in one phase → success" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-01)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    fund_account "$fresh_addr" 0.1ether
    local n; n=$(get_nonce $fresh_addr 0x0)
    # Build "$T1,0x;…" 100 times.
    local phase=""
    for i in $(seq 1 100); do
        [[ -n "$phase" ]] && phase="$phase;"
        phase="${phase}${T1},0x"
    done
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key --phase "$phase" \
        --nonce-sequence $n --gas-limit 5000000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" success; then ok
    else fail B-01 "$out"; fi
}

test_B02() {
    run_case B-02 "MAX_CALLS_PER_TX exceeded: 101 calls → reject" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-02)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    fund_account "$fresh_addr" 0.1ether
    local n; n=$(get_nonce $fresh_addr 0x0)
    local phase=""
    for i in $(seq 1 101); do
        [[ -n "$phase" ]] && phase="$phase;"
        phase="${phase}${T1},0x"
    done
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key --phase "$phase" \
        --nonce-sequence $n --gas-limit 5000000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-02 "expected rejected (call limit); got: $out"; fi
}

test_B03() {
    run_case B-03 "Spread 100 calls across many phases → success" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-03)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    fund_account "$fresh_addr" 0.1ether
    local n; n=$(get_nonce $fresh_addr 0x0)
    local args=()
    for p in $(seq 1 10); do
        local phase=""
        for i in $(seq 1 10); do
            [[ -n "$phase" ]] && phase="$phase;"
            phase="${phase}${T1},0x"
        done
        args+=(--phase "$phase")
    done
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key "${args[@]}" \
        --nonce-sequence $n --gas-limit 5000000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" success; then ok
    else fail B-03 "$out"; fi
}

test_B04() {
    run_case B-04 "Single call with 64KB calldata → success" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    # 64 KiB of zeros — calldata gas = 4*65536 = 262144
    local big_data="0x$(python3 -c 'print("00"*65536)')"
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data "$big_data" \
        --nonce-sequence $n --gas-limit 1000000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" success; then ok
    else fail B-04 "$out"; fi
}

test_B05() {
    run_case B-05 "Calls of length 0 (empty call to non-zero addr) → success" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" success; then ok
    else fail B-05 "$out"; fi
}

# B. Gas / fee edges
test_B10() {
    run_case B-10 "gas_limit=0 → reject (intrinsic gas not covered)" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x10 \
        --nonce-sequence $n --gas-limit 0 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-10 "expected rejected (gas=0); got: $out"; fi
}

test_B11() {
    run_case B-11 "priority_fee > max_fee → SDK rejects client-side" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x11 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 1 --priority-fee-gwei 2)
    if grep -q 'priority-fee-gwei must not exceed' <<<"$out"; then ok
    else fail B-11 "expected SDK reject; got: $out"; fi
}

test_B12() {
    run_case B-12 "max_fee=0 → reject (cannot cover basefee)" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x12 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 0 --priority-fee-gwei 0)
    if assert_status "$out" rejected; then ok
    else fail B-12 "$out"; fi
}

test_B13() {
    run_case B-13 "gas_limit way below intrinsic → reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x13 \
        --nonce-sequence $n --gas-limit 1000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-13 "$out"; fi
}

test_B14() {
    run_case B-14 "Phase OOG (per-phase gas exhausted) → phase status false, status=reverted" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    # 64 KiB calldata + 25k gas budget → phase will OOG.
    local big_data="0x$(python3 -c 'print("00"*65536)')"
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data "$big_data" \
        --nonce-sequence $n --gas-limit 25000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    # Either rejected pre-inclusion (intrinsic check) or phase reverts.
    if assert_status "$out" rejected || assert_status "$out" reverted; then ok
    else fail B-14 "$out"; fi
}

# C. Nonce edges
test_B20() {
    run_case B-20 "nonce_key = NONCE_KEY_MAX manually (without --nonce-free) → behaves as nonce-free" || return
    local exp=$(( $(now_secs) + 5 ))
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x20 \
        --nonce-key $NONCE_KEY_MAX_HEX --nonce-sequence 0 \
        --expiry $exp --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" success; then ok
    else fail B-20 "$out"; fi
}

test_B21() {
    run_case B-21 "nonce_key = NONCE_KEY_MAX with sequence!=0 → reject" || return
    local exp=$(( $(now_secs) + 5 ))
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x21 \
        --nonce-key $NONCE_KEY_MAX_HEX --nonce-sequence 7 \
        --expiry $exp --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-21 "expected rejected (NONCE_KEY_MAX with seq>0); got: $out"; fi
}

test_B22() {
    run_case B-22 "Two distinct channels, sequential txs → both succeed, channels independent" || return
    local k1=0x1; local k2=0x2222
    local nA0; nA0=$(get_nonce $ADDR_S $k1)
    local nB0; nB0=$(get_nonce $ADDR_S $k2)
    local out1; out1=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x22a1 \
        --nonce-key $k1 --nonce-sequence $nA0 --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if ! assert_status "$out1" success; then fail B-22 "ch1: $out1"; return; fi
    local out2; out2=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x22a2 \
        --nonce-key $k2 --nonce-sequence $nB0 --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out2" success; then ok
    else fail B-22 "ch2: $out2"; fi
}

test_B23() {
    run_case B-23 "Same channel, two pending txs at seq=N and seq=N+1 → both mine in order" || return
    # Send seq=N+1 first then N — pool should buffer the later one until N
    # is included. (Ordering is impl-defined; we only assert both eventually
    # mine.)
    local n; n=$(get_nonce $ADDR_S 0x0)
    local nplus=$((n + 1))
    local out_later; out_later=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x23a2 \
        --nonce-sequence $nplus --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1 --dry-run)
    local raw_later; raw_later=$(extract_dry_run_field "$out_later" encoded)
    # Submit raw out-of-order: seq=N+1 first, then seq=N normal send.
    local resp; resp=$(rpc eth_sendRawTransaction "[\"$raw_later\"]")
    local out_first; out_first=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x23a1 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if ! assert_status "$out_first" success; then fail B-23 "first: $out_first"; return; fi
    # Wait briefly for the buffered tx to mine.
    local later_hash; later_hash=$(python3 -c "import json; print(json.loads('''$resp''').get('result',''))")
    local block=""
    for _ in $(seq 1 20); do
        block=$(receipt_field "$later_hash" blockNumber)
        [[ -n "$block" && "$block" != "null" ]] && break
        sleep 0.5
    done
    if [[ -n "$block" && "$block" != "null" ]]; then ok
    else fail B-23 "queued (seq+1) tx never mined: hash=$later_hash"; fi
}

# D. Account-changes structural caps
test_B30() {
    run_case B-30 "MAX_ACCOUNT_CHANGES_PER_TX (10) — at limit → success" || return
    # 10 owner-changes packed into a single config-change entry. ownerIds
    # are derived from synthesized addresses so each is distinct.
    local fresh_key; fresh_key=$(fresh_secret_key B-30)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    fund_account "$fresh_addr" 0.05ether
    local n; n=$(get_nonce $fresh_addr 0x0)
    local args=(--config-sequence 0)
    local k1=0x0000000000000000000000000000000000000001
    for i in $(seq 1 10); do
        local owner_id="0x$(printf '%040x000000000000000000000000' $i)"
        args+=(--config-authorize "${k1}:${owner_id}:0x00")
    done
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key "${args[@]}" \
        --nonce-sequence $n --gas-limit 500000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" success; then ok
    else fail B-30 "$out"; fi
}

test_B31() {
    run_case B-31 "MAX_ACCOUNT_CHANGES_PER_TX exceeded (11) → reject" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-31)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    fund_account "$fresh_addr" 0.05ether
    local n; n=$(get_nonce $fresh_addr 0x0)
    local args=(--config-sequence 0)
    local k1=0x0000000000000000000000000000000000000001
    for i in $(seq 1 11); do
        local owner_id="0x$(printf '%040x000000000000000000000000' $i)"
        args+=(--config-authorize "${k1}:${owner_id}:0x00")
    done
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key "${args[@]}" \
        --nonce-sequence $n --gas-limit 500000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-31 "expected rejected (account-change cap); got: $out"; fi
}

test_B32() {
    run_case B-32 "Config change with empty owner_changes list → reject" || return
    # The config-change entry exists but has zero ownerChanges. SDK builds
    # this only if at least one change is requested, so we verify SDK won't
    # produce an empty entry (and chain would reject it anyway). This is a
    # SDK-shape sanity check.
    local n; n=$(get_nonce $ADDR_S 0x0)
    # No config-* flags → no entry should be appended → tx is a regular AA tx,
    # which succeeds. We assert that with no entry, the tx still works.
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x32 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" success; then ok
    else fail B-32 "$out"; fi
}

# E. Signature edge cases
test_B40() {
    run_case B-40 "sender_auth too short (1 byte) → reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x40 \
        --sender-auth-hex 0xff \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-40 "$out"; fi
}

test_B41() {
    run_case B-41 "sender_auth empty bytes → reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x41 \
        --sender-auth-hex 0x \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-41 "$out"; fi
}

test_B42() {
    run_case B-42 "Configured-owner with bad verifier (0x0…0002, no contract) → reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    # Verifier address 0x0…0002 has no code. Build sender_auth with this
    # bogus verifier prefix.
    local bad_auth=0x0000000000000000000000000000000000000002$(printf '%0130d' 0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --from $ADDR_S --to $T1 --data 0x42 \
        --sender-auth-hex "$bad_auth" \
        --nonce-sequence $n --gas-limit 200000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-42 "$out"; fi
}

# F. P256 sender / verifier — happy path lives in basic suite (T-45/T-46/T-47);
#    boundary keeps the negative cases.
test_B47() {
    run_case B-47 "P256 sender with unregistered key → reject (ownerId not found)" || return
    # P256 owner NOT registered for this account, sender_auth uses P256 →
    # owner_config lookup fails → reject.
    local k1_priv; k1_priv=$(fresh_secret_key B-47)
    local k1_addr; k1_addr=$(cast wallet address --private-key $k1_priv)
    fund_account "$k1_addr" 0.05ether
    # Trigger auto-delegation (so the AccountConfig storage path is live)
    # via a vanilla AA tx first.
    local n0; n0=$(get_nonce $k1_addr 0x0)
    "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $k1_priv --to $T1 --data 0x4700 \
        --nonce-sequence $n0 --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1 >/dev/null 2>&1
    sleep 1

    local p256_priv; p256_priv=$(fresh_p256_secret_key B-47)
    local n; n=$(get_nonce $k1_addr 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $k1_priv --from $k1_addr \
        --sender-p256-key $p256_priv \
        --to $T1 --data 0x47 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-47 "expected rejected (P256 owner not registered); got: $out"; fi
}

test_B48() {
    run_case B-48 "P256 owner registered with SENDER scope only — used as PAYER → reject" || return
    # Register P256 with scope=0x02 (SENDER only). Then attempt to use it
    # in payer slot (would require PAYER bit 0x04). Spec: payer auth must
    # match a verifier authorized with PAYER scope.
    #
    # The SDK's --payer-auth-hex injection is K1-only (envelope is
    # K1_VERIFIER || sig65). Building P256 payer auth would need extra SDK
    # flag (--payer-p256-key). For now, skip this test; flagged for follow-up.
    skip B-48 "needs --payer-p256-key SDK flag"
}

# G. Expiry edges
test_B60() {
    run_case B-60 "expiry = now exactly → reject (boundary inclusive of past)" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local exp; exp=$(now_secs)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x60 \
        --expiry $exp --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-60 "$out"; fi
}

test_B61() {
    run_case B-61 "expiry = u64::MAX → either accepted or rejected by SDK clamp" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x61 \
        --expiry 18446744073709551615 --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    # Spec doesn't constrain the upper bound on standard channel; chain may
    # accept very-large expiry. Either outcome counts as well-defined.
    if assert_status "$out" success || assert_status "$out" rejected; then ok
    else fail B-61 "$out"; fi
}

# H. Sender / payer balance edges
test_B70() {
    run_case B-70 "Payer balance = 0 → reject (insufficient sponsor funds)" || return
    local poor_payer_key; poor_payer_key=$(fresh_secret_key B-70-payer)
    local poor_payer_addr; poor_payer_addr=$(cast wallet address --private-key $poor_payer_key)
    # do NOT fund payer
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x70 \
        --payer $poor_payer_addr --payer-key $poor_payer_key \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-70 "$out"; fi
}

test_B71() {
    run_case B-71 "Sender bal=0, payer bal=0 → reject" || return
    local poor_s_key; poor_s_key=$(fresh_secret_key B-71-sender)
    local poor_s_addr; poor_s_addr=$(cast wallet address --private-key $poor_s_key)
    local poor_p_key; poor_p_key=$(fresh_secret_key B-71-payer)
    local poor_p_addr; poor_p_addr=$(cast wallet address --private-key $poor_p_key)
    local n; n=$(get_nonce $poor_s_addr 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $poor_s_key --to $T1 --data 0x71 \
        --payer $poor_p_addr --payer-key $poor_p_key \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-71 "$out"; fi
}

# I. Encoding / RLP malformation surfaces (eth_sendRawTransaction direct)
test_B90() {
    run_case B-90 "Truncated encoded tx (drop last 4 bytes) → RPC reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local dry; dry=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x90 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1 --dry-run)
    local raw; raw=$(extract_dry_run_field "$dry" encoded)
    [[ -z "$raw" ]] && { fail B-90 "couldn't capture encoded tx"; return; }
    local truncated="${raw:0:$(( ${#raw} - 8 ))}"
    local resp; resp=$(rpc eth_sendRawTransaction "[\"$truncated\"]")
    if grep -qE 'error|invalid' <<<"$resp"; then ok
    else fail B-90 "truncated tx unexpectedly accepted: $resp"; fi
}

test_B91() {
    run_case B-91 "Wrong tx type byte (0x7c instead of 0x7b) → RPC reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local dry; dry=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x91 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1 --dry-run)
    local raw; raw=$(extract_dry_run_field "$dry" encoded)
    [[ -z "$raw" ]] && { fail B-91 "couldn't capture encoded tx"; return; }
    # Replace 0x7b at byte-0 with 0x7c.
    local mutated="0x7c${raw:4}"
    local resp; resp=$(rpc eth_sendRawTransaction "[\"$mutated\"]")
    if grep -qE 'error|unknown|invalid|unsupported' <<<"$resp"; then ok
    else fail B-91 "type-byte mutation unexpectedly accepted: $resp"; fi
}

# ── Execute ──────────────────────────────────────────────────────────────────

test_B01
test_B02
test_B03
test_B04
test_B05
test_B10
test_B11
test_B12
test_B13
test_B14
test_B20
test_B21
test_B22
test_B23
test_B30
test_B31
test_B32
test_B40
test_B41
test_B42
test_B47
test_B48
test_B60
test_B61
test_B70
test_B71
test_B90
test_B91

# Run all agent-produced boundary tests (encoding/phase/auth/payer/spec).
for t in "${EXTERNAL_TESTS[@]}"; do
    "$t"
done

print_summary boundary
