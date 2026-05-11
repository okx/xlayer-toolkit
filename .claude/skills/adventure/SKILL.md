---
name: adventure
description: Run the X Layer "adventure" benchmark tool (ERC20 / native / io / fib / create stress tests on an Optimism L2 using 20k accounts). Use when the user asks to run adventure, benchmark X Layer, or run erc20-bench / native-bench / io-bench / fib-bench / create-bench.
---

# Adventure — X Layer Benchmark Tool

Adventure is a stress-testing tool for X Layer (Optimism L2). It uses ~20,000 accounts to drive concurrent ERC20 / native / io / fib / create workloads against a node and measure performance and stability.

## 0. Adventure directory

The adventure project directory defaults to `tools/adventure` under the current repository root (i.e. `<repo-root>/tools/adventure`). No configuration file is needed — resolve the repo root with `git rev-parse --show-toplevel` and use `$REPO_ROOT/tools/adventure` as the working directory for all commands below.

## 1. Commands

All commands must be executed from the adventure directory (`cd "$(git rev-parse --show-toplevel)/tools/adventure" && ...`).

### ERC20 stress test

```bash
make erc20
# equivalent to:
adventure erc20-init 10ETH -f ./testdata/config.json
adventure erc20-bench -f ./testdata/config.json --contract 0xContractAddress
```

### Native token stress test

```bash
make native
# equivalent to:
adventure native-init 10ETH -f ./testdata/config.json
adventure native-bench -f ./testdata/config.json
```

### IO bench

```bash
make io
# equivalent to:
adventure simulator-init 10ETH -f ./testdata/config.json
adventure io-bench -f ./testdata/config.json
```

### Fib bench

```bash
make fib
# equivalent to:
adventure simulator-init 10ETH -f ./testdata/config.json
adventure fib-bench -f ./testdata/config.json
```

### Create bench

```bash
make create
# equivalent to:
adventure native-init 10ETH -f ./testdata/config.json
adventure create-bench -f ./testdata/config.json
```

### Preconditions to remind the user about

- RPC node reachable (default `http://127.0.0.1:8123`).
- `testdata/config.json` exists and is tuned for the run.
- `testdata/accounts-20k.txt` (20,000 accounts) is present.
- `senderPrivateKey` in `testdata/config.json` has enough balance to fund init.

## 2. Configuration file (`testdata/config.json`)

Editable parameters:

```json
{
  "rpc": ["http://127.0.0.1:8123"],
  "accounts": 20000,
  "senderPrivateKey": "0x...",
  "concurrency": 20,
  "mempoolPauseThreshold": 50000,
  "targetTPS": 0,
  "maxBatchSize": 100,
  "gasPriceGwei": 100,
  "saveTxHashes": false,
  "simulatorParams": {
    "simulatorConfig": {
      "load_accounts": 12,
      "update_accounts": 5,
      "create_accounts": 0,
      "load_storage": 49,
      "update_storage": 9,
      "delete_storage": 0,
      "create_storage": 2,
      "fib": 100
    }
  }
}
```

### Top-level fields

- `rpc` — RPC endpoint URLs (list; transactions are distributed across them).
- `accounts` — number of benchmark accounts used as both senders and receivers. On first run, `testdata/accounts/accounts-<N>.txt` is auto-generated with this many private keys and reused on subsequent runs.
- `senderPrivateKey` — funds contract deployment and token distribution during `*-init` commands.
- `concurrency` — number of concurrent senders.
- `mempoolPauseThreshold` — pause sending when mempool exceeds this size.
- `targetTPS` — target transactions per second; `0` means no rate limit.
- `maxBatchSize` — maximum transactions per batch (default `100`).
- `gasPriceGwei` — gas price in Gwei.
- `saveTxHashes` — when true, writes tx hashes to `./txhashes.log`.

### `simulatorParams.simulatorConfig` (used by `io-bench` / `fib-bench` / `create-bench`)

Parameters passed to the on-chain simulator contract to shape each transaction's workload:

- `load_accounts` — account loads per tx (reads of existing accounts).
- `update_accounts` — account updates per tx.
- `create_accounts` — new accounts created per tx.
- `load_storage` — storage slot reads per tx.
- `update_storage` — storage slot updates per tx.
- `delete_storage` — storage slot deletions per tx.
- `create_storage` — new storage slots written per tx.
- `fib` — Fibonacci iteration count; controls CPU/compute load per tx (used by `fib-bench`).

Treat `senderPrivateKey` as sensitive: never echo or commit it, mask when showing values from the config, and never send it off-machine.

## 3. Behavior

- If the user's request is ambiguous ("run adventure"), ask which workload (erc20 / native / io / fib / create) and whether they want the full `make <target>` flow or a specific step.
- Before running any `make` target, `cd` into `<repo-root>/tools/adventure`.
- Do not modify `testdata/config.json` unless the user asks for a specific change.
- Stream output so the user can watch benchmark progress.
