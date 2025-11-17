# Stress Testing Guide for RPC/Sequencer

This guide explains how to perform comprehensive stress tests on your local RPC node or sequencer using the Adventure tool.

## Prerequisites

1. **Compile the tool**
   ```shell
   make
   ```
   Binary will be installed to `$GOPATH/bin/adventure` (typically `~/go/bin/adventure`)

2. **Add to PATH** (if needed)
   ```shell
   export PATH=$PATH:$(go env GOPATH)/bin
   ```

3. **Start your local RPC/sequencer**
   - For OP Stack: Ensure `op-geth` is running (typically on port 8545)
   - For other chains: Note your RPC endpoint URL

4. **Fund test accounts** (see Account Funding section below)

## Overview of All Stress Test Types

The Adventure tool provides **8 different stress testing commands** to comprehensively test various aspects of your RPC/sequencer:

| Command | Purpose | Use Case |
|---------|---------|----------|
| `transfer` | Native token transfers | Raw transaction throughput |
| `operate` | Smart contract operations | Computational load & gas usage |
| `query` | RPC query APIs | Read performance & indexing |
| `wmt` | Uniswap-style DeFi | Single DeFi protocol stress |
| `multiwmt` | Multi-contract DeFi | Complex DeFi scenarios |
| `scenario` | End-to-end user flows | Real-world usage patterns |
| `txrpc` | Transaction RPC timing | Transaction submission performance |
| `txrlpencode` | RLP encoding generation | Pre-signed transaction batches |

---

## Detailed Command Reference

### 1. Transfer Stress Test (Transaction Throughput)

**Purpose:** Tests raw transaction processing capacity by sending native token transfers.

```shell
adventure evm bench transfer -i http://localhost:8545 -c 100 -t 0
```

**Parameters:**
- `-i, --ips`: Comma-separated RPC endpoints (e.g., `http://localhost:8545,http://localhost:8546`)
- `-c, --concurrency`: Number of concurrent goroutines (default: 1)
- `-t, --sleep`: Sleep time in milliseconds between transactions per goroutine (default: 1000)
- `-p, --private-key-file`: Path to private key file (optional, uses 2000 built-in accounts if omitted)
- `-f, --fixed`: Use fixed recipient address (optional, default: false)

**What it tests:**
- Maximum transactions per second (TPS)
- Mempool handling
- Nonce management
- Network saturation

**Example scenarios:**
```shell
# Low load baseline
adventure evm bench transfer -i http://localhost:8545 -c 10 -t 1000

# Medium load test
adventure evm bench transfer -i http://localhost:8545 -c 100 -t 100

# Maximum throughput test
adventure evm bench transfer -i http://localhost:8545 -c 500 -t 0

# Multi-node load balancing
adventure evm bench transfer -i http://node1:8545,http://node2:8545,http://node3:8545 -c 200 -t 0

# Fixed recipient (tests account state hotspot)
adventure evm bench transfer -i http://localhost:8545 -c 100 -f
```

---

### 2. Contract Operation Stress Test

**Purpose:** Tests smart contract execution performance and computational limits.

**Prerequisites:** Requires deployment of test contracts from [github.com/okex/evm-performance](https://github.com/okex/evm-performance)

```shell
adventure evm bench operate -i http://localhost:8545 -c 100 --opts 1,1,1,1,1 --times 10 --contract 0x... --id 0
```

**Parameters:**
- `-i, --ips`: Comma-separated RPC endpoints
- `-c, --concurrency`: Number of concurrent goroutines
- `-t, --sleep`: Sleep time in milliseconds between operations
- `--contract`: Router contract address or test contract address (required)
- `--id`: Test contract ID in Router (default: 0)
- `--opts`: Execution count for each operation code in a single loop (comma-separated)
- `--times`: Number of loops to execute (required)
- `--direct`: If true, send directly to test contract; if false, send to Router (default: false)

**What it tests:**
- Contract execution speed
- Gas consumption under load
- State database writes
- EVM performance
- Contract call complexity

**Example scenarios:**
```shell
# Light contract operations via Router
adventure evm bench operate -i http://localhost:8545 -c 50 --opts 1,1,1,1,1 --times 1 --contract 0x... --id 0

# Heavy computational load
adventure evm bench operate -i http://localhost:8545 -c 100 --opts 10,10,10,10,10 --times 100 --contract 0x... --id 0

# Direct contract stress test (bypass Router)
adventure evm bench operate -i http://localhost:8545 -c 200 --direct --contract 0x... --opts 5,5,5,5,5 --times 50

# Extreme computational stress
adventure evm bench operate -i http://localhost:8545 -c 300 --opts 100,100,100,100,100 --times 1000 --contract 0x... --id 0
```

---

### 3. RPC Query Stress Test

**Purpose:** Tests read performance and query handling capacity across all standard Ethereum RPC methods.

```shell
adventure evm bench query -i http://localhost:8545 -t 1000 -o 10,10,10,10,10,10,10,10,10
```

**Parameters:**
- `-i, --ips`: RPC endpoint (only uses first endpoint)
- `-t, --sleep`: Sleep time in milliseconds between query rounds (default: 1000)
- `-o, --opts`: Number of goroutines per second for each query type (comma-separated, must be 9 values):
  - Position 0: `eth_blockNumber`
  - Position 1: `eth_getBalance`
  - Position 2: `eth_getBlockByNumber`
  - Position 3: `eth_gasPrice`
  - Position 4: `eth_getCode`
  - Position 5: `eth_getTransactionCount`
  - Position 6: `eth_getTransactionReceipt`
  - Position 7: `net_version`
  - Position 8: `eth_call`

**What it tests:**
- RPC response times
- Query throughput
- Database indexing performance
- Cache effectiveness
- Read path scalability

**Example scenarios:**
```shell
# Balanced query load (5 goroutines/second per query type)
adventure evm bench query -i http://localhost:8545 -t 1000 -o 5,5,5,5,5,5,5,5,5

# Heavy read load (20 goroutines/second per query type)
adventure evm bench query -i http://localhost:8545 -t 100 -o 20,20,20,20,20,20,20,20,20

# Focus on block queries
adventure evm bench query -i http://localhost:8545 -t 500 -o 50,0,50,0,0,0,0,0,0

# Focus on transaction receipts (common query pattern)
adventure evm bench query -i http://localhost:8545 -t 500 -o 0,0,0,0,0,0,50,0,0

# Stress eth_call (contract read calls)
adventure evm bench query -i http://localhost:8545 -t 200 -o 0,0,0,0,0,0,0,0,100

# Disable specific queries (set to 0)
adventure evm bench query -i http://localhost:8545 -t 1000 -o 10,10,10,10,0,10,10,10,10
```

---

### 4. Uniswap-style DeFi Operations (WMT)

**Purpose:** Tests DeFi protocol operations including swaps, liquidity provision, and withdrawals.

**Note:** Designed for OEC testnet but can be adapted for other chains.

```shell
adventure evm bench wmt -i http://localhost:8545 -c 250
```

**Parameters:**
- `-i, --ips`: Comma-separated RPC endpoints
- `-c, --concurrency`: Number of concurrent goroutines (default: 1)
- `-t, --sleep`: Sleep time in milliseconds (default: 1000)
- `-p, --private-key-file`: Path to private key file (optional)

**What it tests:**
- DeFi protocol throughput
- Complex contract interactions
- Token transfers and approvals
- Liquidity pool state management
- Multi-step transaction flows

**Example scenarios:**
```shell
# Moderate DeFi load
adventure evm bench wmt -i http://localhost:8545 -c 100

# High DeFi throughput
adventure evm bench wmt -i http://localhost:8545 -c 250 -t 0

# Multi-node DeFi stress
adventure evm bench wmt -i http://node1:8545,http://node2:8545 -c 500
```

---

### 5. Multi-Contract DeFi Operations (MultiWMT)

**Purpose:** Advanced DeFi stress testing with multiple contracts using configuration files.

**Configuration required:** Create a `wmt.json` config file (see `config/wmt.json` for examples)

#### 5a. Initialize Multi-WMT
```shell
adventure evm bench multiwmt-init -f config/wmt.json
```
Prepares accounts and transfers initial tokens to workers.

#### 5b. Run Multi-WMT Stress Test
```shell
adventure evm bench multiwmt -f config/wmt.json
```
Executes the full DeFi stress test loop.

#### 5c. Check Token Balances
```shell
adventure evm bench multiwmt-token -f config/wmt.json
```
Displays token balances for all worker accounts.

**Parameters:**
- `-f`: Path to WMT configuration file (default: `./config/wmt.json`)

**Config file structure:**
- `RPC`: Array of RPC endpoints
- `SuperAcc`: Funded account private key
- `WorkerPath`: Path to worker account file
- `ContractPath`: Path to contract list
- `ParaNum`: Number of parallel workers
- `SendOKTToWorker`: Amount to send to each worker

**What it tests:**
- Complex multi-contract interactions
- Realistic DeFi workloads
- Multiple concurrent protocols
- Cross-contract state dependencies
- Load distribution across multiple nodes

**Example scenarios:**
```shell
# Initialize for 10 contracts, 1000 workers
adventure evm bench multiwmt-init -f config/devnet/wmt-cList_10-con_1000-val_all.json

# Run stress test
adventure evm bench multiwmt -f config/devnet/wmt-cList_10-con_1000-val_all.json

# Check balances after test
adventure evm bench multiwmt-token -f config/devnet/wmt-cList_10-con_1000-val_all.json
```

---

### 6. Scenario Test (End-to-End User Flows)

**Purpose:** Simulates realistic user scenarios with multiple operations per transaction cycle.

**Flow:** `getBalance` → `transfer` → `getBalance` (verify balance decreased)

```shell
adventure evm bench scenario -i http://localhost:8545 -c 100 -p /path/to/private_keys.txt
```

**Parameters:**
- `-i, --ips`: Comma-separated RPC endpoints
- `-c, --concurrency`: Number of concurrent goroutines
- `-t, --sleep`: Sleep time in milliseconds
- `-p, --private-key-file`: Path to private key file (required for scenario test)
- `-f, --fixed`: Use fixed recipient address (optional)

**What it tests:**
- End-to-end user experience
- Query + transaction combined load
- Balance verification logic
- Real-world usage patterns
- State consistency across operations

**Example scenarios:**
```shell
# Basic scenario test
adventure evm bench scenario -i http://localhost:8545 -c 50 -p config/devnet/addr_50000_transfer

# High concurrency scenarios
adventure evm bench scenario -i http://localhost:8545 -c 200 -p config/devnet/addr_50000_transfer -t 500

# Fixed recipient scenario
adventure evm bench scenario -i http://localhost:8545 -c 100 -p config/devnet/addr_50000_transfer -f
```

---

### 7. Transaction RPC Test (TxRPC)

**Purpose:** Measures transaction submission performance and timing.

```shell
adventure evm bench txrpc -i http://localhost:8545 -c 100
```

**Parameters:**
- `-i, --ips`: Comma-separated RPC endpoints
- `-c, --concurrency`: Number of concurrent goroutines
- `-p, --private-key-file`: Path to private key file (optional)
- `-f, --fixed`: Use fixed recipient address (optional)

**What it tests:**
- Transaction submission latency
- Time to receive transaction hash
- Success ratio under concurrent load
- Average TPS calculation
- Network round-trip time

**Example scenarios:**
```shell
# Measure baseline transaction timing
adventure evm bench txrpc -i http://localhost:8545 -c 100

# High concurrency timing test
adventure evm bench txrpc -i http://localhost:8545 -c 500

# Multi-node timing comparison
adventure evm bench txrpc -i http://node1:8545,http://node2:8545 -c 200
```

---

### 8. Transaction RLP Encode (Pre-generate Signed Transactions)

**Purpose:** Generates RLP-encoded signed transactions for all accounts without sending them.

```shell
adventure evm bench txrlpencode -p /path/to/private_keys.txt
```

**Parameters:**
- `-i, --ips`: RPC endpoint (for querying nonces)
- `-p, --private-key-file`: Path to private key file (optional)

**What it tests:**
- Transaction signing performance
- Batch transaction preparation
- RLP encoding correctness

**Use case:** Pre-generate a large batch of signed transactions for later submission via custom tools.

**Example:**
```shell
# Generate signed transactions for all accounts
adventure evm bench txrlpencode -i http://localhost:8545 -p config/devnet/addr_50000_transfer
```

## Account Funding

Before running stress tests, ensure test accounts have sufficient funds.

### Method 1: Batch Transfer to Built-in Accounts

```shell
adventure evm batch-transfer 10 -i http://localhost:8545 -s <funded_private_key>
```

- Sends 10 tokens to each of the 2000 built-in test accounts
- `-s, --private-key`: Private key with sufficient balance (not mnemonic)
- `-a, --address-file`: Optional custom address file (uses built-in accounts if omitted)

### Method 2: Use Custom Accounts

```shell
adventure evm batch-transfer 100 -i http://localhost:8545 -s <funded_private_key> -a /path/to/addresses.txt
```

Then run stress tests with:
```shell
adventure evm bench transfer -i http://localhost:8545 -c 100 -p /path/to/private_keys.txt
```

## Test Duration

**Important**: All stress tests run **indefinitely** until manually stopped.

- Press **Ctrl+C** to stop the test
- Monitor your metrics during the test
- Typical test duration: 5-60 minutes depending on what you're measuring

## Comprehensive Testing Strategy

### Quick Start: Choose Your Test Type

**For basic throughput testing:**
```shell
adventure evm bench transfer -i http://localhost:8545 -c 100 -t 0
```

**For contract-heavy workloads:**
```shell
adventure evm bench operate -i http://localhost:8545 -c 100 --opts 1,1,1,1,1 --times 10 --contract 0x...
```

**For read-heavy workloads:**
```shell
adventure evm bench query -i http://localhost:8545 -t 1000 -o 10,10,10,10,10,10,10,10,10
```

**For DeFi workloads:**
```shell
adventure evm bench wmt -i http://localhost:8545 -c 250
```

**For realistic user scenarios:**
```shell
adventure evm bench scenario -i http://localhost:8545 -c 100 -p config/devnet/addr_50000_transfer
```

---

### Detailed Multi-Phase Strategy

#### Phase 1: Baseline (Low Load)
```shell
adventure evm bench transfer -i http://localhost:8545 -c 10 -t 1000
```
- Establish baseline performance
- Monitor CPU, memory, disk I/O
- Check block production consistency

#### Phase 2: Gradual Increase
```shell
# Increase concurrency progressively
adventure evm bench transfer -i http://localhost:8545 -c 50 -t 500
adventure evm bench transfer -i http://localhost:8545 -c 100 -t 100
adventure evm bench transfer -i http://localhost:8545 -c 200 -t 50
```
- Find performance degradation points
- Track transaction inclusion rate
- Watch for error patterns

#### Phase 3: Maximum Throughput
```shell
adventure evm bench transfer -i http://localhost:8545 -c 500 -t 0
```
- Determine maximum sustainable TPS
- Identify bottlenecks
- Test recovery behavior

#### Phase 4: Query Load (Separate Test)
```shell
adventure evm bench query -i http://localhost:8545 -t 100 -o 20,20,20,20,20,20,20,20,20
```
- Test read path independently
- Measure RPC response times
- Assess indexing performance

#### Phase 5: Mixed Workload (Advanced)
Run multiple stress tests simultaneously in separate terminals:
```shell
# Terminal 1: Write load
adventure evm bench transfer -i http://localhost:8545 -c 200 -t 0

# Terminal 2: Read load
adventure evm bench query -i http://localhost:8545 -t 500 -o 10,10,10,10,10,10,10,10,10

# Terminal 3: Contract operations
adventure evm bench operate -i http://localhost:8545 -c 50 --opts 5,5,5,5,5 --times 10 --contract 0x...
```
- Simulates realistic production load
- Tests interaction between read and write paths
- Identifies resource contention issues

## Metrics to Monitor

During stress testing, monitor:

1. **Sequencer/Node Metrics:**
   - CPU usage
   - Memory consumption
   - Disk I/O
   - Network bandwidth

2. **Blockchain Metrics:**
   - Block production rate
   - Transactions per block
   - Gas usage per block
   - Mempool size

3. **Application Metrics:**
   - Transaction inclusion rate
   - Transaction confirmation time
   - RPC response latency
   - Error rates in logs

4. **Adventure Tool Output:**
   - Transaction hashes logged
   - Error messages (insufficient funds, mempool full, etc.)
   - Nonce management issues

## Troubleshooting

### "insufficient funds for gas" Error
```
2025/11/17 17:42:16 [g0] 0x24835C6b439A293FA537b39ea21eC13042A72f31 send tx err: insufficient funds for gas * price + value: have 0 want 31000000000000
```

**Solution:** Fund the test accounts first:
```shell
adventure evm batch-transfer 100 -i http://localhost:8545 -s <funded_private_key>
```

### "mempool is full" Error

**Solution:**
- Reduce concurrency (`-c` value)
- Increase sleep time (`-t` value)
- Your sequencer may need configuration tuning

### "invalid nonce" Error

**Solution:** The tool handles this automatically, but if persistent:
- Reduce concurrency
- Check for network latency issues

## Tips

1. **Start small**: Begin with low concurrency and gradually increase
2. **Use multiple endpoints**: Load balance across multiple nodes with `-i node1,node2,node3`
3. **Monitor continuously**: Set up monitoring before starting tests
4. **Test different scenarios**: Combine transfer, contract, and query tests
5. **Document results**: Keep notes on configuration and performance metrics
6. **Test recovery**: Stop and restart tests to verify node recovery behavior

## For OP Stack Sequencers

When testing OP Stack:
- Send transactions to **op-geth** (execution layer, port 8545)
- Do NOT send to op-node (rollup node, port 9545)
- op-node handles L1/L2 communication internally

Verify your endpoint:
```shell
curl -X POST http://localhost:8545 -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```
