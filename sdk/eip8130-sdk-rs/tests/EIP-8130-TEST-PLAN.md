# EIP-8130 Test Plan

End-to-end test matrix for the X Layer port of [EIP-8130 — Account
Abstraction by Account Configuration](https://github.com/ethereum/EIPs/blob/master/EIPS/eip-8130.md),
exercised against a running devnet via the
[`eip8130-send`](../README.md) CLI.

## Environment

| Component | Default value |
|---|---|
| Devnet root | `/Users/xzavieryuan/workspace/op-dev/xlayer-toolkit/devnet` |
| L2 RPC | `http://localhost:8123` (op-reth-seq) |
| L2 Chain ID | `195` (`0xc3`) |
| Sender (well-funded EOA) | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` (mnemonic key index 1) |
| Payer (well-funded EOA) | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` (mnemonic key index 2) |
| Mnemonic | `test test test test test test test test test test test junk` |

System addresses (op-alloy fork):

| Constant | Value |
|---|---|
| `AA_TX_TYPE` | `0x7B` |
| `AA_PAYER_TYPE` | `0x7C` |
| `NONCE_KEY_MAX` | `2^256 − 1` |
| `NONCE_MANAGER_ADDRESS` | `0x000000000000000000000000000000000000aa02` (precompile) |
| `TX_CONTEXT_ADDRESS` | `0x000000000000000000000000000000000000aa03` (precompile) |
| `DEFAULT_ACCOUNT_ADDRESS` | `0x31914Dd8C3901448D787b2097744Bf7D3241E85A` |
| `ACCOUNT_CONFIG_ADDRESS` | `0x4F20618Cf5c160e7AA385268721dA968F86F0e61` |
| `ECRECOVER_VERIFIER` (= K1) | `0x0000000000000000000000000000000000000001` |
| `REVOKED_VERIFIER` | `0xffffffffffffffffffffffffffffffffffffffff` |

## Test matrix

Tests are grouped by EIP-8130 spec section. Each row records:

- **ID** — stable handle (`T-NN`).
- **Pre-state** — fixture / nonce / balance assumptions.
- **Action** — `eip8130-send` invocation.
- **Expected on-chain effect** — receipt fields, post-state queries.
- **Failure shape** — for negative tests, the mempool / validator error.

Conventions:

- *Receipt assertions* are read via `eth_getTransactionReceipt` and
  expected to deserialize as `op_alloy_rpc_types::OpTransactionReceipt`.
- *Phase-status assertions* read `eip8130Fields.phaseStatuses` —
  per-phase boolean array (success=`true`, revert=`false`, skipped=`false`).
- Negative tests assert `eth_sendRawTransaction` returns an error JSON
  payload; the test runner greps for the substring listed below.

### A. Tx Type & Encoding

| ID | Description | Action | Expected |
|---|---|---|---|
| T-01 | Type byte 0x7B accepted | EOA self-pay, single call | `receipt.type = 0x7b`, `status = 0x1`, `phaseStatuses=[true]` |
| T-02 | Empty calls (no-op tx) | `--phase ""` (zero phases) | `status=0x1`, `phaseStatuses=[]` |

### B. Calls / Phases

| ID | Description | Expected |
|---|---|---|
| T-03 | Multi-call atomic batch (1 phase, 2 calls) | `phaseStatuses=[true]`, both target addresses receive value |
| T-04 | Multi-phase (2 phases × 1 call) | `phaseStatuses=[true,true]` |
| T-05 | 3 phases × 2 calls each | `phaseStatuses=[true,true,true]` |

### C. 2D Nonce

| ID | Description | Expected |
|---|---|---|
| T-10 | Sequential channel-0 nonces | After 3 txs, `eth_getTransactionCount(addr, latest, 0x0)` returns previous + 3 |
| T-11 | Parallel channels (key=0 and key=0xdead) increment independently | After 1 tx in each, both channels show seq=1 |
| T-12 | Wrong nonce → reject | error contains `nonce mismatch` or `expected … got …` |

### D. Nonce-Free Mode (`NONCE_KEY_MAX`)

| ID | Description | Expected |
|---|---|---|
| T-20 | Nonce-free with valid expiry (now+5s) | accepted, `phaseStatuses=[true]` |
| T-21 | Nonce-free with `nonce_sequence != 0` | reject (`nonce_sequence must be 0` or similar) |
| T-22 | Nonce-free with `expiry == 0` | reject (`expiry required for nonce-free`) |
| T-23 | Nonce-free expiry too far (now + 60s) | reject (`expiry exceeds … window`) |

### E. Expiry

| ID | Description | Expected |
|---|---|---|
| T-30 | `expiry = now + 60s` (standard channel) | accepted |
| T-31 | `expiry = now − 10s` (past) | reject (`expired`) |

### F. Signature & Verification

| ID | Description | Expected |
|---|---|---|
| T-40 | EOA path (from empty) | accepted (already covered by T-01) |
| T-41 | Configured-owner path (from set, ECRECOVER_VERIFIER) | accepted via implicit EOA rule (slot empty + ownerId == bytes20(account)) |
| T-42 | Bad signature (random sig bytes) | reject (`invalid sender_auth` / `signature recovery failed`) |
| T-43 | sender_auth length wrong (e.g. 64 bytes in EOA) | reject (`EOA sender_auth must be exactly 65 bytes`) |

### G. Self-Pay vs Sponsored

| ID | Description | Expected |
|---|---|---|
| T-50 | Sponsored (different payer + valid payer_auth) | `receipt.payer == ADDR2`, sender's balance unchanged for gas, payer's balance decreased |
| T-51 | Sponsored with wrong payer signature (random sig) | reject (`payer not authorized` / `payer_auth`) |
| T-52 | Sponsored with payer that has zero balance | reject (`insufficient balance`) |

### G2. Cross-sender Payer Replay (security)

| ID | Description | Expected |
|---|---|---|
| T-55 | Payer signs hash-with-substituted-sender from EOA-A. Try replay with EOA-B | **POSITIVE OUTCOME**: reject (`payer not authorized` because hash differs) |

> **Status**: Spec mandates substitution (§Cross-sender Payer Replay). On
> the original fork rev (`8cabdd41…`) the validator did NOT substitute,
> so T-55 would FAIL. After fix (`payer_signature_hash_with_resolved_sender`)
> T-55 PASSES — see [BUG-001 in TEST-REPORT.md](./EIP-8130-TEST-REPORT.md).

### H. Receipt Format

| ID | Description | Expected |
|---|---|---|
| T-60 | Receipt has type=`0x7b` | already covered |
| T-61 | Receipt has `payer` field | covered (T-01 self-pay; T-50 sponsored) |
| T-62 | Receipt `phaseStatuses.length == calls.length` | covered (T-03..T-05) |
| T-63 | Phase revert: phase 0 revert → `phaseStatuses=[false]` | We trigger revert by calling 0xFE-stubbed precompile address |

### I. Auto-Delegation

| ID | Description | Expected |
|---|---|---|
| T-70 | Fresh EOA's first AA tx → account auto-delegated | After tx: `eth_getCode(sender) == 0xef0100 || DEFAULT_ACCOUNT_ADDRESS` (23 bytes) |
| T-71 | Already-delegated account: tx doesn't change code | Code unchanged |

### J. Account Changes

| ID | Description | Expected |
|---|---|---|
| T-80 | Delegation entry: set custom target | After tx: `eth_getCode(sender) == 0xef0100 || target` |
| T-81 | Delegation entry: clear (target=0x000…000) | `eth_getCode(sender) == 0x` (empty) |

> **Note**: Config-change entries (`type 0x01`) need an `auth` signed
> over the EIP-712 typed digest `SignedOwnerChanges`. The current SDK
> doesn't implement that signer — see TODO in `build_account_changes`.
> For owner registration / revocation tests, use
> `applySignedOwnerChanges()` via EVM (out of this CLI's scope).

### K. RPC

| ID | Description | Expected |
|---|---|---|
| T-90 | `eth_getTransactionCount(addr, latest, nonceKey)` returns 2D nonce | matches incremented value after txs |

## Out-of-scope (deferred)

These spec sections require deeper devnet setup or signer support not
yet in the SDK. Marked as deferred with a tracking link in the report.

- **Account Lock** — needs `lock(unlockDelay)` + `initiateUnlock()` via
  EVM. ACCOUNT_CONFIG_ADDRESS has empty code on the running devnet, so
  lock state can't be set without first deploying the contract.
- **Create entry (account_changes type 0x00)** — CREATE2 address
  derivation + deployment header construction. Requires SDK work to
  build the salt commitment and validate `code_size(from) == 0`.
- **Config-change entry (type 0x01) signing** — requires the EIP-712
  `SignedOwnerChanges` digest signer.
- **Custom verifier contracts** (P256, WebAuthn, etc.) — needs
  contracts deployed on the devnet.

## Running the suite

```bash
# Make sure the devnet is up:
cd /Users/xzavieryuan/workspace/op-dev/xlayer-toolkit/devnet
docker compose ps   # all op-* services healthy

# Build the SDK once:
cd /Users/xzavieryuan/workspace/op-dev/eip8130-sdk-rs
cargo build --release

# Run the matrix:
./tests/run-eip8130-tests.sh

# Or a single test:
./tests/run-eip8130-tests.sh T-50
```

The runner emits a TAP-style line per test plus a final summary table.
A non-zero exit code means at least one test failed.
