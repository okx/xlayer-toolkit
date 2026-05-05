# eip8130-sdk-rs

Minimal Rust SDK / CLI for sending [EIP-8130](https://eips.ethereum.org/EIPS/eip-8130)
(X Layer Native AA) transactions.

Reuses the canonical types from
[`okx/optimism`](https://github.com/okx/optimism) (the OP Stack monorepo
that hosts X Layer's EIP-8130 port) for guaranteed encoding/signing
compatibility with the chain.

## Quick start

```bash
cargo run --release -- \
    --rpc-url http://localhost:8545 \
    --chain-id 196 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
    --to 0x0000000000000000000000000000000000000042 \
    --data 0xdeadbeef \
    --gas-limit 100000 \
    --max-fee-gwei 2 \
    --priority-fee-gwei 1 \
    --nonce-sequence 0
```

Pass `--dry-run` to print the encoded tx hex without broadcasting.

## What this SDK does

The simplest possible EIP-8130 invocation:

| Aspect | This SDK |
|---|---|
| Sender mode | EOA (sender derived via `ecrecover` from `sender_auth`) |
| Verifier | K1 native (secp256k1 ECDSA) |
| Phases | Single phase, single call |
| Account changes | None |
| Payer | None (self-pay) |
| Expiry | None (or set via `--expiry`) |

## Sign-and-send flow (matches the protocol)

1. Build the unsigned `TxEip8130` (sender_auth = empty placeholder).
2. Compute `sender_signature_hash(tx)` — uses the protocol's custom encoding,
   not the standard EIP-2718 hash.
3. Sign the hash with secp256k1, get a recoverable signature.
4. Pack as `r(32) || s(32) || v(1)` where `v = 27 + recovery_id`.
5. Set `tx.sender_auth` to the 65-byte signature.
6. RLP-encode with EIP-2718 type byte: `0x7B || rlp(tx)`.
7. Submit via `eth_sendRawTransaction`.

## Out of scope (deliberate)

To keep the SDK small and self-explanatory, these are not implemented:

- **Configured-owner mode** (`tx.from = Some(...)` with on-chain config):
  needs `AccountConfiguration` to be deployed and an owner registered
  with a verifier address.
- **Sponsored gas** (separate payer + `payer_auth`): needs a payer
  signature against `payer_signature_hash(tx)`.
- **Multi-phase calls or `account_changes`**: single-phase only.
- **Reading `nonce_sequence` from `NonceManager`** via
  `eth_call(getNonce(addr, key))` at `0x0000…aa02` — pass `--nonce-sequence`
  manually for now.
- **Custom verifiers** (P256, WebAuthn, custom contracts): K1 only.

The op-alloy / op-revm crates exposed by `okx/optimism` already include
the primitives needed to build any of the above on top of this scaffold.

## Pinning

The dep on `op-alloy-consensus` is pinned to a specific commit
(`1bf7c64ee481fa5dd6d7f1bd07d923ed9f58e7ad`) so the encoding stays
stable. Bump that rev only when both ends of the chain (the SDK and the
node) advance together.
