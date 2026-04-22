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
  "gasPriceGwei": 100,
  "saveTxHashes": false
}
```

- **rpc**: RPC endpoint URLs
- **accountsFilePath**: Path to test accounts file (20,000 accounts)
- **senderPrivateKey**: Private key for deploying contracts and distributing tokens
- **concurrency**: Number of concurrent senders
- **mempoolPauseThreshold**: Mempool size threshold (pause sending when exceeded)
- **gasPriceGwei**: Gas price in Gwei
- **saveTxHashes**: Enable saving transaction hashes to `./txhashes.log` (default: false)
