# Adventure - X Layer Benchmark Tool

## 📖 Background

Adventure is a stress testing tool for X Layer (Optimism L2), using **20,000 accounts** for concurrent ERC20 token and native token transfer benchmarks to evaluate chain performance and stability.

## 🚀 Usage

```bash
# ERC20 token stress test (deploy contract + distribute tokens + benchmark)
make erc20

# Or run manually:
adventure erc20-init 10ETH -f ./testdata/config.json 
adventure erc20-bench -f ./testdata/config.json --contract 0xContractAddress

# Gasless ERC20 stress test (deploy + register as gasless token + zero-gas-price benchmark)
make gasless
make gasless GASLESS_SCENARIO=approve   # run the approve scenario instead of transfer

# Or run manually (devnet: --contract is the gasless-init ERC20, used as both approve/transfer token):
# On 1952 / 196, set tokenApprove / tokenTransfer / approveSpender in config.json. No need to set --contract.
adventure gasless-init -f ./testdata/config.json
adventure gasless-bench -f ./testdata/config.json --scenario transfer --contract 0x8464135c8F25Da09e49BC8782676a84730C318bC

# On 1952 / 196, set tokenApprove / tokenTransfer / approveSpender in config.json to
# already-whitelisted tokens and run the bench directly (no --contract):
# On devnet set tokenApprove in config.json or --contract 0xContractAddress
adventure gasless-bench -f ./testdata/config.json --scenario approve

# Partition accounts across two benches running at the same time (no account/nonce collisions) via
# the accountOffset config field — see Configuration below. accountOffset applies to BOTH init and
# bench, so each partition runs its OWN init+bench with the SAME offset (init funds exactly the
# slice its bench sends from). config-gasless.json: "accountOffset":"0:1000"; config-erc20.json: "1000:5000":
adventure gasless-init  -f ./testdata/config-gasless.json                              # funds 0..999 + registers gasless token
adventure gasless-bench -f ./testdata/config-gasless.json --contract 0x<gaslessERC20>  # sends from 0..999
adventure erc20-init 10ETH -f ./testdata/config-erc20.json                             # funds 1000..4999 + deploys token
adventure erc20-bench   -f ./testdata/config-erc20.json   --contract 0x<erc20>         # sends from 1000..4999

# Hybrid stress test: alternates one gasless transfer and one normal (gas-paying) ERC20 transfer of
# the same token. hybrid-init deploys + whitelists an ERC20 and funds accounts with native gas AND
# the token.
make hybrid

# Or run manually (devnet: --contract is the hybrid-init ERC20, overriding config tokenTransfer):
adventure hybrid-init 10ETH -f ./testdata/config.json
adventure hybrid-bench -f ./testdata/config.json --contract 0xContractAddress

# On 1952 / 196, set tokenTransfer in config.json to an already gasless-whitelisted token and run the
# bench directly (no --contract):
adventure hybrid-bench -f ./testdata/config.json

# Native token stress test (distribute tokens + benchmark)
make native

# Or run manually:
adventure native-init 10ETH -f ./testdata/config.json
adventure native-bench -f ./testdata/config.json

# io bench
make io

# Or run manually:
adventure simulator-init 10ETH -f ./testdata/config.json
adventure io-bench -f ./testdata/config.json


# fib bench
make fib

# Or run manually:
adventure simulator-init 10ETH -f ./testdata/config.json
adventure fib-bench -f ./testdata/config.json

# create bench
make create

# Or run manually:
adventure native-init 10ETH -f ./testdata/config.json
adventure create-bench -f ./testdata/config.json


```

**Notes:**
- Ensure RPC node is running (default: `http://127.0.0.1:8123`)
- Configuration file located at `testdata/config.json`
- Test accounts file is auto-generated at `testdata/accounts/accounts-<N>.txt` from the `accounts` config value (e.g. `accounts-5000.txt` for 5000 accounts)
- Sender private key (for initialization) is configured in `testdata/config.json`

## 📝 Configuration

Edit `testdata/config.json` to adjust benchmark parameters:

```json
{
  "rpc": ["http://127.0.0.1:8123"],
  "accounts": 5000,
  "accountOffset": "",
  "senderPrivateKey": "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "concurrency": 20,
  "mempoolPauseThreshold": 50000,
  "targetTPS": 0,
  "maxBatchSize": 100,
  "gasPriceGwei": 100,
  "saveTxHashes": false,
  "tokenApprove": "",
  "approveSpender": "0x203B9aD06aeb929427E233587F0020661dd23B11",
  "tokenTransfer": "",
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

- **rpc**: RPC endpoint URLs (list; transactions are distributed across them)
- **accounts**: Number of benchmark accounts to use as both senders and receivers. On first run, `testdata/accounts/accounts-<N>.txt` is auto-generated with this many private keys and reused on subsequent runs
- **accountOffset**: Optional half-open sub-range `"start:end"` of the accounts file — `"0:4000"` uses accounts `0..3999`. Empty (the default) uses **all** accounts. It applies to **both** `*-init` (funds that slice) and `*-bench` (sends from that slice)
- **senderPrivateKey**: Private key used by `*-init` commands to deploy contracts and distribute tokens to the benchmark accounts
- **tokenApprove** / **tokenTransfer**: Gasless-whitelisted ERC20 used by `gasless-bench` for the `approve` / `transfer` scenarios respectively. On the local devnet (chain id 195) these are left empty and overridden by `gasless-init`'s freshly deployed ERC20 (the Makefile passes it via `--contract`); on 1952 / 196 set them to already-whitelisted tokens. `gasless-bench` sends zero-gas-price legacy transactions (gas price forced to `0`, ignoring `gasPriceGwei`); the node accepts them only because the token is whitelisted
- **approveSpender**: Spender address passed to `approve(spender, 0)` in the gasless `approve` scenario (any address works). Defaults to `0x203B9aD06aeb929427E233587F0020661dd23B11`

Note: on chain id 195 only, `gasless-init` enables gasless and registers the deployed ERC20 as a gasless transfer token using a built-in devnet owner key — no owner key is needed in the config.
- **concurrency**: Number of concurrent senders
- **mempoolPauseThreshold**: Mempool size threshold; sending pauses when the pending pool exceeds this value
- **targetTPS**: Target transactions per second. `0` means no rate limit
- **maxBatchSize**: Maximum transactions per batch (default `100`)
- **gasPriceGwei**: Gas price in Gwei
- **saveTxHashes**: Enable saving transaction hashes to `./txhashes.log` (default: `false`)

### `simulatorParams.simulatorConfig` (used by `io-bench` / `fib-bench`)

These parameters are passed to the on-chain simulator contract to shape each transaction's workload:

- **load_accounts**: Number of account loads per tx (reads of existing accounts)
- **update_accounts**: Number of account updates per tx
- **create_accounts**: Number of new accounts created per tx
- **load_storage**: Number of storage slot reads per tx
- **update_storage**: Number of storage slot updates per tx
- **delete_storage**: Number of storage slot deletions per tx
- **create_storage**: Number of new storage slots written per tx
- **fib**: Fibonacci iteration count — controls CPU/compute load per tx (used by `fib-bench`)
