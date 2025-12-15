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
  "accountsFilePath": "./testdata/accounts-20k.txt",
  "senderPrivateKey": "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "concurrency": 20,
  "batchConcurrency": 5,
  "mempoolPauseThreshold": 50000,
  "gasPriceGwei": 100,
  "saveTxHashes": false
}
```

- **rpc**: RPC endpoint URLs
- **accountsFilePath**: Path to test accounts file (20,000 accounts)
- **senderPrivateKey**: Private key for deploying contracts and distributing tokens
- **concurrency**: Number of concurrent senders (main goroutines)
- **batchConcurrency**: Max concurrent batches per goroutine (default: 5, prevents nonce issues)
- **mempoolPauseThreshold**: Mempool size threshold (pause sending when exceeded)
- **gasPriceGwei**: Gas price in Gwei
- **saveTxHashes**: Enable saving transaction hashes to `./txhashes.log` (default: false)

### Concurrency Notes

With the improved batch concurrency implementation:
- Each of the `concurrency` goroutines processes accounts in batches of 100
- Within each goroutine, up to `batchConcurrency` batches are sent concurrently
- **Effective concurrency** = `concurrency × batchConcurrency`
- For 20k accounts with `concurrency: 20` and `batchConcurrency: 5`: **100 concurrent batches**
- Adjust `batchConcurrency` based on your node's capacity:
  - Lower (2-5): More stable, fewer nonce errors
  - Higher (10-20): Higher throughput, may cause nonce issues under load

**Troubleshooting:** If you see "nonce too low" errors, see [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) for solutions.

See [CONCURRENCY_FIX.md](./CONCURRENCY_FIX.md) for technical details.

## 📊 Understanding TPS Metrics

The tool reports two types of TPS:

### Interval (Instant) TPS
```
[Interval] Instant TPS: 0.50 (over last 5.0s)
```
- **What it measures**: Actual on-chain transaction processing rate
- **When to use**: Real-time monitoring of blockchain throughput
- **Should match**: What you see in Reth/sequencer logs

### Overall (Average) TPS
```
[Overall] Avg TPS: 1.25, Total Txs: 10, Duration: 8s
```
- **What it measures**: Cumulative transactions over total test duration
- **When to use**: Long-term performance benchmarking

**Important**: In earlier versions, TPS measured transaction *submission* rate (how fast the tool sent transactions), not actual blockchain *processing* rate. This has been fixed. See [TPS_FIX.md](./TPS_FIX.md) for details.

### Reading the Output

Example output:
```
========================================================
[TPS log] StartBlock: 100, EndBlock: 102, Blocks: 2, TxsInInterval: 2
[Interval] Instant TPS: 0.40 (over last 5.0s)
[Overall] Avg TPS: 1.25, Max TPS: 0.50, Min TPS: 0.20, Total Txs: 10, Duration: 8s
========================================================
```

- **TxsInInterval**: Transactions confirmed in the last reporting period
- **Blocks**: Number of new blocks in this interval
- **Instant TPS**: Current blockchain throughput (TxsInInterval / interval duration)
- **Avg TPS**: Overall test performance (Total Txs / Total Duration)
- **Max/Min TPS**: Based on interval measurements, shows performance variance
