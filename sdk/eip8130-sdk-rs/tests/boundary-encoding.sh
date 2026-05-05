# EIP-8130 BOUNDARY-ENCODING e2e tests (B-100..B-149).
#
# Sourced by run-boundary-tests.sh. Focus: byte-level RLP / 2718 envelope
# mutations, field range edges (chain_id / gas_limit / max_fee / expiry),
# `from`/`to` address oddities, calldata edges, and account_changes ordering.
#
# Defines test_BXXX functions and exports BOUNDARY_ENCODING_TESTS at the end.
# All tests use the runner-provided helpers (run_case, ok, fail, verbose_run,
# rpc, get_nonce, fresh_secret_key, fund_account, extract_dry_run_field,
# classify_outcome, assert_status). Globals: RPC_URL, CHAIN_ID, SDK_BIN,
# ADDR_S/KEY_S, ADDR_P/KEY_P, T1, T2, T3, T_REVERT, NONCE_KEY_MAX_HEX.

# ── A. EIP-2718 type-byte / envelope mutations ──────────────────────────────

# tx.rs:395-398 — encode_2718 prepends AA_TX_TYPE_ID (0x7b). A wrong type
# byte must round-trip-fail in Decodable2718::typed_decode (tx.rs:402-405).
test_B100() {
    run_case B-100 "type byte 0x00 instead of 0x7b → RPC reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local dry; dry=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x0100 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1 --dry-run)
    local raw; raw=$(extract_dry_run_field "$dry" encoded)
    [[ -z "$raw" ]] && { fail B-100 "couldn't capture encoded tx"; return; }
    # Replace 0x7b at byte-0 with 0x00. After "0x" prefix, first 2 hex chars
    # are the type byte.
    local mutated="0x00${raw:4}"
    local resp; resp=$(rpc eth_sendRawTransaction "[\"$mutated\"]")
    if grep -qE 'error|invalid|unknown|unsupported' <<<"$resp"; then ok
    else fail B-100 "type-byte=0x00 unexpectedly accepted: $resp"; fi
}

# Encodable2718 prepends exactly one type-byte; dropping it leaves a bare
# RLP list that decodes as a legacy tx and must be rejected.
test_B101() {
    run_case B-101 "drop type prefix entirely (raw RLP list, no 0x7b) → RPC reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local dry; dry=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x0101 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1 --dry-run)
    local raw; raw=$(extract_dry_run_field "$dry" encoded)
    [[ -z "$raw" ]] && { fail B-101 "couldn't capture encoded tx"; return; }
    local mutated="0x${raw:4}"
    local resp; resp=$(rpc eth_sendRawTransaction "[\"$mutated\"]")
    if grep -qE 'error|invalid|unknown|unsupported|rlp' <<<"$resp"; then ok
    else fail B-101 "type-byte-stripped tx unexpectedly accepted: $resp"; fi
}

# Prepending an extra leading byte breaks the EIP-2718 framing: 0x7b is
# expected at byte 0, anything else (or extra prefix) must reject.
test_B102() {
    run_case B-102 "prepend extra byte before 0x7b → RPC reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local dry; dry=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x0102 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1 --dry-run)
    local raw; raw=$(extract_dry_run_field "$dry" encoded)
    [[ -z "$raw" ]] && { fail B-102 "couldn't capture encoded tx"; return; }
    local mutated="0xff${raw:2}"
    local resp; resp=$(rpc eth_sendRawTransaction "[\"$mutated\"]")
    if grep -qE 'error|invalid|unknown|unsupported|rlp' <<<"$resp"; then ok
    else fail B-102 "extra-prefix tx unexpectedly accepted: $resp"; fi
}

# Append junk bytes after the well-formed tx → tx.rs:258 length check
# (`buf.len() + header.payload_length != remaining`) must reject.
test_B103() {
    run_case B-103 "trailing junk bytes after RLP list → RPC reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local dry; dry=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x0103 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1 --dry-run)
    local raw; raw=$(extract_dry_run_field "$dry" encoded)
    [[ -z "$raw" ]] && { fail B-103 "couldn't capture encoded tx"; return; }
    # Append 4 bytes of junk after the RLP payload.
    local mutated="${raw}deadbeef"
    local resp; resp=$(rpc eth_sendRawTransaction "[\"$mutated\"]")
    if grep -qE 'error|invalid|rlp|trailing|length' <<<"$resp"; then ok
    else fail B-103 "trailing-junk tx unexpectedly accepted: $resp"; fi
}

# Mutate the outer RLP list-length byte — byte 1 of the encoded blob is the
# RLP header. Bumping it by +1 (or any value) makes header.payload_length
# disagree with the actual buffer → tx.rs:258 rejects.
test_B104() {
    run_case B-104 "corrupt outer RLP list-length prefix → RPC reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local dry; dry=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x0104 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1 --dry-run)
    local raw; raw=$(extract_dry_run_field "$dry" encoded)
    [[ -z "$raw" ]] && { fail B-104 "couldn't capture encoded tx"; return; }
    # XOR 0x01 into the byte right after type-byte (byte index 1 in the
    # decoded stream — char index 4..6 in the 0x-prefixed hex string).
    local mutated; mutated=$(python3 -c "
raw = '$raw'.removeprefix('0x')
b = bytearray.fromhex(raw)
b[1] ^= 0x01
print('0x' + b.hex())
")
    local resp; resp=$(rpc eth_sendRawTransaction "[\"$mutated\"]")
    if grep -qE 'error|invalid|rlp|length' <<<"$resp"; then ok
    else fail B-104 "list-length mutation accepted: $resp"; fi
}

# RLP truncation past header but before payload end. Differs from B-90
# (drop 4 bytes from tail of full encoded) by trimming a larger chunk
# right inside the sender_auth field — must error in
# Decodable::decode for Bytes (UnexpectedLength).
test_B105() {
    run_case B-105 "truncate inside sender_auth field → RPC reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local dry; dry=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x0105 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1 --dry-run)
    local raw; raw=$(extract_dry_run_field "$dry" encoded)
    [[ -z "$raw" ]] && { fail B-105 "couldn't capture encoded tx"; return; }
    # Drop ~1/3 of the bytes from the tail (well past the header,
    # firmly inside the auth blobs).
    local mutated; mutated=$(python3 -c "
raw = '$raw'.removeprefix('0x')
keep = len(raw) - max(len(raw) // 3, 32)  # at least 16 bytes off
print('0x' + raw[:keep])
")
    local resp; resp=$(rpc eth_sendRawTransaction "[\"$mutated\"]")
    if grep -qE 'error|invalid|rlp|length|short' <<<"$resp"; then ok
    else fail B-105 "mid-payload truncation accepted: $resp"; fi
}

# ── B. chain_id / gas_limit / fee range edges ───────────────────────────────

# tx.rs:31 (chain_id: u64). Sending with chain_id=0 doesn't match the node's
# CHAIN_ID and must be rejected at the chain-id check.
test_B110() {
    run_case B-110 "chain_id = 0 (mismatch) → reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id 0 \
        --private-key $KEY_S --to $T1 --data 0x0110 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-110 "expected rejected (chain_id=0); got: $out"; fi
}

# chain_id = u64::MAX (18446744073709551615) doesn't match the node either
# → reject.
test_B111() {
    run_case B-111 "chain_id = u64::MAX (mismatch) → reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL \
        --chain-id 18446744073709551615 \
        --private-key $KEY_S --to $T1 --data 0x0111 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-111 "expected rejected (chain_id=u64::MAX); got: $out"; fi
}

# tx.rs:53 (gas_limit: u64). u64::MAX vastly exceeds block gas limit and
# must be rejected (gas limit > block limit OR insufficient sender balance
# for max_fee*gas_limit).
test_B112() {
    run_case B-112 "gas_limit = u64::MAX → reject (exceeds block limit / balance)" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x0112 \
        --nonce-sequence $n --gas-limit 18446744073709551615 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-112 "expected rejected (gas=u64::MAX); got: $out"; fi
}

# tx.rs:47 (max_fee_per_gas: u128). max_fee = u128::MAX requires a balance
# >= u128::MAX * gas_limit which any account on devnet lacks → reject.
# SDK takes max_fee_gwei (u128); u128::MAX gwei is well into the rejection
# regime; we use a near-max value that's still valid u128 arithmetic.
test_B113() {
    run_case B-113 "max_fee per gas = u128::MAX gwei → reject (insufficient balance)" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    # u128::MAX = 340282366920938463463374607431768211455. Pass as decimal.
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x0113 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 340282366920938463463374607431768211455 \
        --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-113 "expected rejected (max_fee=u128::MAX); got: $out"; fi
}

# tx.rs:41 (expiry: u64). expiry = 1 is in the distant past (Unix epoch +
# 1s) → ValidationError::Expired.
test_B114() {
    run_case B-114 "expiry = 1 (epoch+1s) → reject (expired)" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x0114 \
        --expiry 1 --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-114 "expected rejected (expiry=1); got: $out"; fi
}

# ── C. `from` field oddities (configured-owner mode) ────────────────────────

# tx.rs:33 (from: Option<Address>). `--from 0x0…0` in configured-owner mode
# means "address zero is the sender". No owner is registered for 0x0…0 →
# ValidationError::SenderNotAuthorized.
test_B120() {
    run_case B-120 "from = 0x0…0 in configured-owner mode → reject (no owner)" || return
    local n; n=$(get_nonce 0x0000000000000000000000000000000000000000 0x0)
    [[ "$n" == "-1" ]] && n=0
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S \
        --from 0x0000000000000000000000000000000000000000 \
        --to $T1 --data 0x0120 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-120 "expected rejected (from=0x0); got: $out"; fi
}

# `--from 0xff…ff` is the REVOKED_VERIFIER address — using it as `from`
# can't auth (no owner config) → reject.
test_B121() {
    run_case B-121 "from = 0xff…ff (REVOKED_VERIFIER addr) → reject" || return
    local n=0
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S \
        --from 0xffffffffffffffffffffffffffffffffffffffff \
        --to $T1 --data 0x0121 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-121 "expected rejected (from=0xff…ff); got: $out"; fi
}

# `--from 0x…aa02` is the NonceManager precompile address. Calling AA tx
# with this as the sender (the precompile has no private key, no owner
# registration) → reject.
test_B122() {
    run_case B-122 "from = NonceManager precompile (0x…aa02) → reject" || return
    local n=0
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S \
        --from 0x000000000000000000000000000000000000aa02 \
        --to $T1 --data 0x0122 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-122 "expected rejected (from=NonceManager precompile); got: $out"; fi
}

# ── D. Calldata edges ────────────────────────────────────────────────────────

# tx.rs:55 (calls: Vec<Vec<Call>>). Single phase, single call with empty
# data → covered by B-05 already as the sender path; this exercises the
# multi-phase "to,data;to,data" parser at empty data on every call.
test_B130() {
    run_case B-130 "multi-phase, every call has 0-byte data → success" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S \
        --phase "$T1,0x;$T2,0x" --phase "$T3,0x" \
        --nonce-sequence $n --gas-limit 200000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" success; then ok
    else fail B-130 "$out"; fi
}

# Exactly 32-byte calldata — boundary between word-aligned and tail bytes.
# Targets without code accept any calldata; tx must succeed.
test_B131() {
    run_case B-131 "calldata exactly 32 bytes (one EVM word) → success" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local data="0x$(python3 -c 'print("ab"*32)')"
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data "$data" \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" success; then ok
    else fail B-131 "$out"; fi
}

# Calldata = 31 bytes (sub-word) — encoding-wise this is a non-trivial RLP
# string with a 1-byte length prefix; ensures encoder handles non-aligned
# sizes.
test_B132() {
    run_case B-132 "calldata 31 bytes (sub-word, 0x80…0xb7 RLP boundary) → success" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local data="0x$(python3 -c 'print("cd"*31)')"
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data "$data" \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" success; then ok
    else fail B-132 "$out"; fi
}

# ── E. `to` field edges (Call.to is a non-Optional Address) ──────────────────

# Per tx.rs:463 (`is_create() -> false`), EIP-8130 has no contract
# creation. `to=0x0…0` is a normal call to address(0); 0x0 has no code
# on devnet, so the call no-ops → tx succeeds.
test_B140() {
    run_case B-140 "to = 0x0…0 (no CREATE; call to address(0)) → success" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S \
        --to 0x0000000000000000000000000000000000000000 --data 0x0140 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" success; then ok
    else fail B-140 "$out"; fi
}

# Self-call: `to = sender` (ADDR_S has no code on devnet → no-op call).
# Validates that the sender-as-target case doesn't trip self-reference
# checks (none should exist in EIP-8130).
test_B141() {
    run_case B-141 "to = self (ADDR_S with no code) → success" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $ADDR_S --data 0x0141 \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" success; then ok
    else fail B-141 "$out"; fi
}

# `to = ECRECOVER (0x01)` — calling a precompile from inside an AA call
# phase is allowed; ECRECOVER with empty calldata returns empty (no
# revert) → tx succeeds.
test_B142() {
    run_case B-142 "to = ECRECOVER precompile (0x01) with empty data → success" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S \
        --to 0x0000000000000000000000000000000000000001 --data 0x \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" success; then ok
    else fail B-142 "$out"; fi
}

# ── F. account_changes ordering ──────────────────────────────────────────────

# validation.rs:178-220 — account_changes structural rules:
#   * ConfigChange has no positional restriction (only Create must be
#     first; Delegation must be ≤1).
# A tx with [ConfigChange, Delegation] should be valid: SDK emits config
# entries before delegations (main.rs:535-540), so this is the natural
# order. We assert the natural order is accepted.
test_B143() {
    run_case B-143 "account_changes order [ConfigChange, Delegation] → success" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-143)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    fund_account "$fresh_addr" 0.05ether
    local n; n=$(get_nonce $fresh_addr 0x0)
    # Authorize a dummy second owner (config-change entry) AND set a
    # delegation target (delegation entry). SDK emits config first, then
    # delegation — matching natural emission order.
    local k1=0x0000000000000000000000000000000000000001
    local owner_id="0x$(printf '%040x000000000000000000000000' 7)"
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key \
        --config-authorize "${k1}:${owner_id}:0x00" \
        --config-sequence 0 \
        --delegation-target $T1 \
        --nonce-sequence $n --gas-limit 500000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" success; then ok
    else fail B-143 "$out"; fi
}

# Ensure the runner sees this list. Append to it (basic + this file may be
# sourced together).
BOUNDARY_ENCODING_TESTS=(
    test_B100 test_B101 test_B102 test_B103 test_B104 test_B105
    test_B110 test_B111 test_B112 test_B113 test_B114
    test_B120 test_B121 test_B122
    test_B130 test_B131 test_B132
    test_B140 test_B141 test_B142
    test_B143
)
