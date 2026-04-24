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
- Test accounts file is `testdata/accounts-20k.txt` (20,000 accounts)
- Sender private key (for initialization) is configured in `testdata/config.json`

## 📝 Configuration

Edit `testdata/config.json` to adjust benchmark parameters:

```json
{
  "rpc": ["http://127.0.0.1:8123"],
  "accounts": 20000,
  "senderPrivateKey": "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
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

- **rpc**: RPC endpoint URLs (list; transactions are distributed across them)
- **accounts**: Number of benchmark accounts to use as both senders and receivers. On first run, `testdata/accounts/accounts-<N>.txt` is auto-generated with this many private keys and reused on subsequent runs
- **senderPrivateKey**: Private key used by `*-init` commands to deploy contracts and distribute tokens to the benchmark accounts
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
