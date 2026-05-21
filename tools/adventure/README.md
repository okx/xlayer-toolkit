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


# EIP-8130 AA bench
make aa sig=secp tx=native
make aa sig=secp tx=erc20
make aa sig=p256 tx=native
make aa sig=p256 tx=erc20
make aa sig=secp tx=native noncekey=1,4 payer=sender
make aa sig=secp tx=native noncekey=max payer=random
make aa sig=secp tx=native noncekey=0 payer=sender gaslimit=55000

# Or run manually:
adventure native-init 10ETH -f ./testdata/config.json
adventure aa-bench -f ./testdata/config.json --sig secp --tx native --noncekey 0 --payer random
adventure aa-bench -f ./testdata/config.json --sig secp --tx native --noncekey 1,4 --payer sender
adventure aa-bench -f ./testdata/config.json --sig secp --tx native --noncekey 0 --payer sender --gaslimit 55000

adventure erc20-init 10ETH -f ./testdata/config.json
adventure aa-bench -f ./testdata/config.json --sig secp --tx erc20 --contract 0xContractAddress --noncekey max --payer random

# p256 sender auth needs owner config once before aa-bench:
adventure aa-init -f ./testdata/config.json --sig p256
```

**Notes:**
- Ensure RPC node is running (default: `http://127.0.0.1:8123`)
- Configuration file located at `testdata/config.json`
- Test accounts file is `testdata/accounts-20k.txt` (20,000 accounts)
- Sender private key (for initialization) is configured in `testdata/config.json`
- `make aa` accepts Make variables (`sig=secp|p256`, `tx=native|erc20`, `noncekey=0|1,4|max`, `payer=sender|random`, `gaslimit=<uint64>`). `make` itself does not support `-sig`; use `sig=...` / `tx=...`.
- `make aa tx=erc20` deploys ERC20 through `erc20-init` and passes the parsed contract address to `aa-bench`, matching the regular `make erc20` flow.
- `--noncekey 0` sends all AA transactions to lane 0. `--noncekey 1,4` round-robins across nonce keys 1, 2, 3, and 4; `--noncekey 1,1` only uses lane 1. `--noncekey max` uses `U256::MAX`; the current 8130 implementation treats this as nonce-free, so the tool encodes `nonce_sequence=0` with a short non-zero expiry based on the latest L2 block timestamp.
- `--payer sender` leaves both `payer` and `payer_auth` empty so the sender pays. `--payer random` randomly selects a benchmark account as payer and includes its K1 payer signature.
- AA transactions are EIP-8130 type `0x7b`, contain one call, and `sig` selects the sender auth mode.
- `--gaslimit 0` (the default) selects a mode-specific AA gas limit: `55000` for `sig=secp tx=native payer=sender`, plus extra headroom for ERC20, P256 sender auth, or random payer auth. Use `gaslimit=...` / `--gaslimit ...` to override it for packing experiments.
- In the current reth 8130 wire format, call entries carry `to` and `data` only; `tx=native` is therefore an empty-calldata native call to a deterministic inert recipient address outside the benchmark sender set, while `tx=erc20` calls `transfer(address,uint256)`.
- `sig=p256` uses the native P256Raw verifier for sender auth and requires `AccountConfiguration` to be deployed at `0xf946601D5424118A4e4054BB0B13133f216b4FeE` before `aa-init --sig p256` can register P256 owners. `aa-init` submits and waits for those config-change transactions before `aa-bench`; it does not deploy the system contract itself.

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
