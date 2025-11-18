# Stress Testing Guide for RPC/Sequencer

This guide explains how to perform comprehensive stress tests on your local RPC node or sequencer using the [Adventure](https://github.com/cuiweixie/adventure/tree/leo/contract-deploy) tool.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Overview of All Stress Test Types](#overview-of-all-stress-test-types)
- [Quick Reference](#quick-reference)
- [Detailed Command Reference](#detailed-command-reference)
- [Using Configuration Files](#using-configuration-files)
- [Using Helper Scripts](#using-helper-scripts)
- [Monitoring & Debugging Scripts](#monitoring--debugging-scripts)
- [Account Funding](#account-funding)
- [Comprehensive Testing Strategy](#comprehensive-testing-strategy)
- [Metrics to Monitor](#metrics-to-monitor)
- [Troubleshooting](#troubleshooting)
- [Tips](#tips)

## Prerequisites

1. **Compile the tool**
   ```shell
   make
   ```
   Binary will be installed to `$GOPATH/bin/adventure` (typically `~/go/bin/adventure`)

   **Important:** If you pull updates from the repository, always run `make` again to rebuild the binary with the latest commands.

2. **Add to PATH** (if needed)
   ```shell
   export PATH=$PATH:$(go env GOPATH)/bin
   ```

   Or use the full path:
   ```shell
   $GOPATH/bin/adventure
   ```

3. **Verify installation**
   ```shell
   adventure evm bench --help
   ```
   You should see all available bench commands listed.

4. **Start your local RPC/sequencer**
   - For OP Stack: Ensure `op-geth` is running (typically on port 8545)
   - For other chains: Note your RPC endpoint URL

5. **Fund test accounts** (see Account Funding section below)

## Overview of All Stress Test Types

The Adventure tool provides **15+ different stress testing commands** to comprehensively test various aspects of your RPC/sequencer:

| Command | Purpose | Use Case |
|---------|---------|----------|
| `transfer` | Native token transfers | Raw transaction throughput |
| `erc20` | ERC20 token transfers | Token contract stress testing |
| `erc20-init` | Deploy ERC20 & fund accounts | Setup for ERC20 testing |
| `operate` | Smart contract operations | Computational load & gas usage |
| `query` | RPC query APIs | Read performance & indexing |
| `wmt` | Uniswap-style DeFi | Single DeFi protocol stress |
| `multiwmt` | Multi-contract DeFi | Complex DeFi scenarios |
| `multiwmt-init` | Initialize multi-WMT | Setup for multi-DeFi testing |
| `multiwmt-token` | Check multi-WMT balances | Verify DeFi token balances |
| `scenario` | End-to-end user flows | Real-world usage patterns |
| `txrpc` | Transaction RPC timing | Transaction submission performance |
| `txrlpencode` | RLP encoding generation | Pre-signed transaction batches |
| `script` | Inscription transactions | X1 network inscriptions |
| `celt-init` | Initialize CELT testing | Setup for CELT protocol |
| `celt` | CELT protocol testing | CELT-specific stress testing |
| `xen` | XEN protocol testing | XEN crypto stress testing |
| `contract-deploy` | Deploy test contracts | Setup for contract testing |
| `polybridge` | Polynetwork bridge testing | Cross-chain bridge stress |

## Quick Reference

**Three Ways to Run Stress Tests:**

1. **Direct Command Line** - Fine-grained control with CLI flags
   ```shell
   adventure evm bench transfer -i http://localhost:8123 -c 100 -t 0
   ```

2. **Configuration Files** - Reproducible tests with JSON configs
   ```shell
   adventure evm bench transfer --f ./config/poly_test/fork6_transfer.json
   ```

3. **Helper Scripts** - Automated workflows for common scenarios
   ```shell
   ./1-setup.sh && ./2-bench-erc20.sh
   ```

---

## Detailed Command Reference

### 1. Transfer Stress Test (Transaction Throughput)

**Purpose:** Tests raw transaction processing capacity by sending native token transfers.

```shell
adventure evm bench transfer -i http://localhost:8123 -c 100 -t 0
```

**Parameters:**
- `-i, --ips`: Comma-separated RPC endpoints (e.g., `http://localhost:8123,http://localhost:8546`)
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
adventure evm bench transfer -i http://localhost:8123 -c 10 -t 1000

# Medium load test
adventure evm bench transfer -i http://localhost:8123 -c 100 -t 100

# Maximum throughput test
adventure evm bench transfer -i http://localhost:8123 -c 500 -t 0

# Multi-node load balancing
adventure evm bench transfer -i http://node1:8545,http://node2:8545,http://node3:8545 -c 200 -t 0

# Fixed recipient (tests account state hotspot)
adventure evm bench transfer -i http://localhost:8123 -c 100 -f
```

---

### 2. Contract Operation Stress Test

**Purpose:** Tests smart contract execution performance and computational limits.

**Prerequisites:** Requires deployment of test contracts from [github.com/okex/evm-performance](https://github.com/okex/evm-performance)

```shell
adventure evm bench operate -i http://localhost:8123 -c 100 --opts 1,1,1,1,1 --times 10 --contract 0x... --id 0
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
adventure evm bench operate -i http://localhost:8123 -c 50 --opts 1,1,1,1,1 --times 1 --contract 0x... --id 0

# Heavy computational load
adventure evm bench operate -i http://localhost:8123 -c 100 --opts 10,10,10,10,10 --times 100 --contract 0x... --id 0

# Direct contract stress test (bypass Router)
adventure evm bench operate -i http://localhost:8123 -c 200 --direct --contract 0x... --opts 5,5,5,5,5 --times 50

# Extreme computational stress
adventure evm bench operate -i http://localhost:8123 -c 300 --opts 100,100,100,100,100 --times 1000 --contract 0x... --id 0
```

---

### 3. RPC Query Stress Test

**Purpose:** Tests read performance and query handling capacity across all standard Ethereum RPC methods.

```shell
adventure evm bench query -i http://localhost:8123 -t 1000 -o 10,10,10,10,10,10,10,10,10
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
adventure evm bench query -i http://localhost:8123 -t 1000 -o 5,5,5,5,5,5,5,5,5

# Heavy read load (20 goroutines/second per query type)
adventure evm bench query -i http://localhost:8123 -t 100 -o 20,20,20,20,20,20,20,20,20

# Focus on block queries
adventure evm bench query -i http://localhost:8123 -t 500 -o 50,0,50,0,0,0,0,0,0

# Focus on transaction receipts (common query pattern)
adventure evm bench query -i http://localhost:8123 -t 500 -o 0,0,0,0,0,0,50,0,0

# Stress eth_call (contract read calls)
adventure evm bench query -i http://localhost:8123 -t 200 -o 0,0,0,0,0,0,0,0,100

# Disable specific queries (set to 0)
adventure evm bench query -i http://localhost:8123 -t 1000 -o 10,10,10,10,0,10,10,10,10
```

---

### 4. Uniswap-style DeFi Operations (WMT)

**Purpose:** Tests DeFi protocol operations including swaps, liquidity provision, and withdrawals.

**Note:** Designed for OEC testnet but can be adapted for other chains.

```shell
adventure evm bench wmt -i http://localhost:8123 -c 250
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
adventure evm bench wmt -i http://localhost:8123 -c 100

# High DeFi throughput
adventure evm bench wmt -i http://localhost:8123 -c 250 -t 0

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
adventure evm bench scenario -i http://localhost:8123 -c 100 -p /path/to/private_keys.txt
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
adventure evm bench scenario -i http://localhost:8123 -c 50 -p config/devnet/addr_50000_transfer

# High concurrency scenarios
adventure evm bench scenario -i http://localhost:8123 -c 200 -p config/devnet/addr_50000_transfer -t 500

# Fixed recipient scenario
adventure evm bench scenario -i http://localhost:8123 -c 100 -p config/devnet/addr_50000_transfer -f
```

---

### 7. Transaction RPC Test (TxRPC)

**Purpose:** Measures transaction submission performance and timing.

```shell
adventure evm bench txrpc -i http://localhost:8123 -c 100
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
adventure evm bench txrpc -i http://localhost:8123 -c 100

# High concurrency timing test
adventure evm bench txrpc -i http://localhost:8123 -c 500

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
adventure evm bench txrlpencode -i http://localhost:8123 -p config/devnet/addr_50000_transfer
```

---

## Using Configuration Files

Many stress tests support configuration files for easier management and reproducibility.

### Transfer with Config File

```shell
adventure evm bench transfer --f ./config/poly_test/fork6_transfer.json
```

**Config file structure** (`fork6_transfer.json`):
```json
{
  "rpc": ["http://127.0.0.1:8123"],
  "accountsFilePath": "./config/devnet/addr_20000_wmt",
  "concurrency": 20,
  "threshold": 50000,
  "gasPrice": 9
}
```

### ERC20 Token Stress Test

The codebase includes additional commands for ERC20 token stress testing:

#### 1. Deploy ERC20 Contract and Fund Accounts
```shell
adventure evm bench erc20-init <amount_per_account_in_wei> \
  -i http://127.0.0.1:8123 \
  -a ./config/devnet/addr_20000_wmt \
  -s <funded_private_key>
```

**Important:** The first argument is the **amount per account in wei**, not total amount.

**Examples:**
```shell
# Fund each account with 1 ETH (requires ~20,000 ETH total for 20k accounts)
adventure evm bench erc20-init 1000000000000000000 \
  -i http://127.0.0.1:8123 \
  -a ./config/devnet/addr_20000_wmt \
  -s <funded_private_key>

# Fund each account with 0.1 ETH (requires ~2,000 ETH total for 20k accounts)
adventure evm bench erc20-init 100000000000000000 \
  -i http://127.0.0.1:8123 \
  -a ./config/devnet/addr_20000_wmt \
  -s <funded_private_key>

# Fund each account with 0.01 ETH (requires ~200 ETH total for 20k accounts)
adventure evm bench erc20-init 10000000000000000 \
  -i http://127.0.0.1:8123 \
  -a ./config/devnet/addr_20000_wmt \
  -s <funded_private_key>
```

**What it does:**
- Deploys BatchTransfer contract for native tokens
- Deploys ERC20 contract
- Deploys BatchTransfer contract for ERC20 tokens
- Transfers native tokens to all addresses (for gas)
- Transfers ERC20 tokens to all addresses
- Output the ERC20 contract address

**Total funds needed:** `amount_per_account * number_of_accounts * 2` (native + ERC20)

#### 2. Run ERC20 Transfer Stress Test
```shell
adventure evm bench erc20 --f ./config/poly_test/fork6_erc20.json --contract 0x...
```

**Config file structure** (`fork6_erc20.json`):
```json
{
  "rpc": ["http://127.0.0.1:8123"],
  "accountsFilePath": "./config/devnet/addr_20000_wmt",
  "concurrency": 20,
  "threshold": 50000,
  "gasPrice": 9
}
```

### Scription (X1 Inscriptions)

```shell
adventure evm bench script --f ./config/poly_test/fork6_script.json
```

For sending inscription-style transactions to X1 network.

---

## Using Helper Scripts

The repository includes shell scripts to automate common workflows. These scripts simplify the process by chaining commands and managing configuration.

### Available Helper Scripts

| Script | Description | What It Does |
|--------|-------------|--------------|
| `1-setup.sh` | ERC20 setup (20K accounts) | Deploy ERC20 contract, fund 20,000 accounts, save address to `.env` |
| `2-bench-erc20.sh` | ERC20 stress test | Run ERC20 transfer stress test using contract from `.env` |
| `3-bench-native.sh` | Native transfer stress test | Run native token transfer stress test |
| `4-setup-addr10.sh` | ERC20 setup (10 accounts) | Deploy ERC20 contract, fund 10 accounts, save address to `.env` |
| `5-bench-erc20-addr10.sh` | ERC20 test (10 accounts) | Run ERC20 stress test with 10 accounts |
| `6-cd-addr10.sh` | Change directory setup | Setup for alternative account configuration |
| `7-bench-native-addr10.sh` | Native test (10 accounts) | Run native transfer stress test with 10 accounts |
| `8-setup-addr10-2.sh` | Alternative setup (10 accounts) | Alternative setup configuration for 10 accounts |
| `9-setup-addr10-3.sh` | Another setup variant | Third setup variant for 10 accounts |
| `9-setup-addr10-combined-30.sh` | Combined setup (30 accounts) | Setup for 30 combined accounts |
| `10-setup-wmt.sh` | Multi-WMT initialization | Initialize multi-contract DeFi setup |
| `11-wmt.sh` | Multi-WMT stress test | Run multi-contract DeFi stress test |
| `check_random_tx.sh` | Transaction checker | Randomly check transaction status in latest block |
| `txpool.sh` | Mempool status | Query mempool pending/queued transactions |

### Basic ERC20 Workflow

**Prerequisites:** The scripts use hardcoded private keys that need to have sufficient funds on your RPC endpoint.

Before running the scripts, either:
1. Fund the hardcoded address: `0xC951181A1BC142Cf9d162C18f2233ea09931e6EA` (from private key `815405dddb0e2a99b12af775fd2929e526704e1d1aea6a0b4e74dc33e2f7fcd2`)
2. Or edit the script to use your own funded private key

#### Step 1: Setup (Deploy Contract & Fund Accounts)
```shell
./1-setup.sh
```

**What it does:**
- Deploys ERC20 contract
- Funds 20,000 test accounts from `./config/devnet/addr_20000_wmt`
- Saves contract address to `.env` file

**Script internals:**
- Uses private key: `815405dddb0e2a99b12af775fd2929e526704e1d1aea6a0b4e74dc33e2f7fcd2`
- Runs: `adventure evm bench erc20-init 100000000000000000000 -i http://127.0.0.1:8123 -a ./config/devnet/addr_20000_wmt -s <private_key>`
- **WARNING:** The amount `100000000000000000000` (100 ETH per account) requires ~2,000,000 ETH total for 20,000 accounts!

**To customize the script:**
Edit `1-setup.sh` and:
1. Replace the `-s` parameter value with your funded private key
2. **Change the amount** to something reasonable (e.g., `10000000000000000` = 0.01 ETH per account = 200 ETH total)

#### Step 2: Run ERC20 Stress Test
```shell
./2-bench-erc20.sh
```
- Reads contract address from `.env`
- Runs ERC20 transfer stress test with config: `./config/poly_test/fork6_erc20.json`
- Uses 20 concurrent goroutines (configurable in the JSON file)
- **Runs INDEFINITELY - Press Ctrl+C to stop**

#### Step 3: Run Native Transfer Stress Test
```shell
./3-bench-native.sh
```
- Runs native token transfer stress test with config: `./config/poly_test/fork6_erc20.json`
- **Runs INDEFINITELY - Press Ctrl+C to stop**

**Complete workflow:**
```shell
# Setup (takes a few minutes)
./1-setup.sh

# Run ERC20 stress test (runs forever until Ctrl+C)
./2-bench-erc20.sh
# Monitor for 5-10 minutes, then press Ctrl+C

# Run native transfer stress test (runs forever until Ctrl+C)
./3-bench-native.sh
# Monitor for 5-10 minutes, then press Ctrl+C
```

### Multi-WMT DeFi Workflow

#### Step 1: Initialize Multi-WMT
```shell
./10-setup-wmt.sh
```
- Initializes multi-contract DeFi setup
- Uses config: `./config/poly_test/poly_multi_wmt-cList_5.json`
- Deploys contracts and funds workers

#### Step 2: Run Multi-WMT Stress Test
```shell
./11-wmt.sh
```
- Executes DeFi stress test with 5 contracts
- Uses config: `./config/poly_test/poly_multi_wmt-cList_5.json`

**Complete workflow:**
```shell
./10-setup-wmt.sh && ./11-wmt.sh
```

### Alternative Account Configurations

The repository includes scripts for different account set sizes (useful for local testing with fewer accounts):

```shell
# Setup with 10 accounts
./4-setup-addr10.sh

# Run ERC20 test with 10 accounts
./5-bench-erc20-addr10.sh

# Run native transfer with 10 accounts
./7-bench-native-addr10.sh
```

**Use cases:**
- **20K accounts** (scripts 1-3): Production-scale stress testing
- **10 accounts** (scripts 4-7): Quick local testing and debugging
- **Custom configurations** (scripts 8-9): Alternative setup patterns

---

## Monitoring & Debugging Scripts

### Check Transaction Status
```shell
./check_random_tx.sh
```

This script:
- Gets the latest block
- Randomly selects a transaction
- Checks transaction receipt
- Displays transaction status and gas usage

**Output example:**
```
📊 交易状态结果:
区块高度: 12345
交易索引: 5
交易位置: 6/20
交易hash: 0x...
Gas使用量: 21000
交易状态: 0x1
✅ 状态说明: 交易成功
```

### Check Mempool Status
```shell
./txpool.sh
```

Queries the `txpool_status` RPC method to see pending and queued transactions.

**Output example:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "pending": "0x64",
    "queued": "0x0"
  }
}
```

---

## Account Funding

Before running stress tests, ensure test accounts have sufficient funds.

### Method 1: Batch Transfer to Built-in Accounts

```shell
adventure evm batch-transfer 10 -i http://localhost:8123 -s <funded_private_key>
```

- Sends 10 tokens to each of the 2000 built-in test accounts
- `-s, --private-key`: Private key with sufficient balance (not mnemonic)
- `-a, --address-file`: Optional custom address file (uses built-in accounts if omitted)

### Method 2: Use Custom Accounts

```shell
adventure evm batch-transfer 100 -i http://localhost:8123 -s <funded_private_key> -a /path/to/addresses.txt
```

Then run stress tests with:
```shell
adventure evm bench transfer -i http://localhost:8123 -c 100 -p /path/to/private_keys.txt
```

### Method 3: Use Helper Scripts

For ERC20 tokens, use the automated setup script:
```shell
./1-setup.sh  # Deploys ERC20 and funds accounts
```

For native tokens, use batch-transfer:
```shell
adventure evm batch-transfer 100 -i http://localhost:8123 -s <funded_private_key> -a ./config/devnet/addr_20000_wmt
```

## Test Duration

**IMPORTANT**: All bench stress tests run **indefinitely** until manually stopped.

### How to Stop Tests
- Press **Ctrl+C** to stop any running test
- The test will continue sending transactions in a loop until you interrupt it
- No automatic stop condition or time limit

### Recommended Test Duration
- **Baseline tests**: 5-10 minutes
- **Load tests**: 10-30 minutes
- **Endurance tests**: 30-60 minutes
- **Soak tests**: Several hours

### What "Indefinitely" Means
When you run commands like:
- `adventure evm bench transfer ...`
- `adventure evm bench erc20 ...`
- `adventure evm bench query ...`
- `./2-bench-erc20.sh`
- `./3-bench-native.sh`

They will continuously send transactions in an infinite loop. You **must** manually stop them with Ctrl+C.

### Exceptions (Commands that DO stop automatically)
- `adventure evm bench txrpc` - Runs once per concurrency level then calculates stats
- `adventure evm bench txrlpencode` - Generates transactions once then exits
- Setup scripts like `./1-setup.sh` - Complete after deployment and funding

## Comprehensive Testing Strategy

### Quick Start: Choose Your Test Type

**For basic throughput testing:**
```shell
adventure evm bench transfer -i http://localhost:8123 -c 100 -t 0
```

**For contract-heavy workloads:**
```shell
adventure evm bench operate -i http://localhost:8123 -c 100 --opts 1,1,1,1,1 --times 10 --contract 0x...
```

**For read-heavy workloads:**
```shell
adventure evm bench query -i http://localhost:8123 -t 1000 -o 10,10,10,10,10,10,10,10,10
```

**For DeFi workloads:**
```shell
adventure evm bench wmt -i http://localhost:8123 -c 250
```

**For realistic user scenarios:**
```shell
adventure evm bench scenario -i http://localhost:8123 -c 100 -p config/devnet/addr_50000_transfer
```

---

### Detailed Multi-Phase Strategy

#### Phase 1: Baseline (Low Load)
```shell
adventure evm bench transfer -i http://localhost:8123 -c 10 -t 1000
```
- Establish baseline performance
- Monitor CPU, memory, disk I/O
- Check block production consistency

#### Phase 2: Gradual Increase
```shell
# Increase concurrency progressively
adventure evm bench transfer -i http://localhost:8123 -c 50 -t 500
adventure evm bench transfer -i http://localhost:8123 -c 100 -t 100
adventure evm bench transfer -i http://localhost:8123 -c 200 -t 50
```
- Find performance degradation points
- Track transaction inclusion rate
- Watch for error patterns

#### Phase 3: Maximum Throughput
```shell
adventure evm bench transfer -i http://localhost:8123 -c 500 -t 0
```
- Determine maximum sustainable TPS
- Identify bottlenecks
- Test recovery behavior

#### Phase 4: Query Load (Separate Test)
```shell
adventure evm bench query -i http://localhost:8123 -t 100 -o 20,20,20,20,20,20,20,20,20
```
- Test read path independently
- Measure RPC response times
- Assess indexing performance

#### Phase 5: Mixed Workload (Advanced)
Run multiple stress tests simultaneously in separate terminals:
```shell
# Terminal 1: Write load
adventure evm bench transfer -i http://localhost:8123 -c 200 -t 0

# Terminal 2: Read load
adventure evm bench query -i http://localhost:8123 -t 500 -o 10,10,10,10,10,10,10,10,10

# Terminal 3: Contract operations
adventure evm bench operate -i http://localhost:8123 -c 50 --opts 5,5,5,5,5 --times 10 --contract 0x...
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

### "unknown shorthand flag" or "command not found" Error

```
Error: unknown shorthand flag: 'a' in -a
```

or

```
Error: unknown command "erc20-init" for "adventure evm bench"
```

**Solution:** You need to rebuild the binary after pulling updates:
```shell
make
```

Then verify the commands are available:
```shell
adventure evm bench --help
```

You should see all commands including `erc20-init`, `celt-init`, `xen`, `script`, etc.

### "insufficient funds for gas" Error

#### During stress test execution:
```
2025/11/17 17:42:16 [g0] 0x24835C6b439A293FA537b39ea21eC13042A72f31 send tx err: insufficient funds for gas * price + value: have 0 want 31000000000000
```

**Solution:** Fund the test accounts first:
```shell
adventure evm batch-transfer 100 -i http://localhost:8123 -s <funded_private_key>
```

#### During setup scripts (e.g., `./1-setup.sh`):
```
2025/11/18 09:32:11 failed to deploy BatchTransfer for Native Token, error: insufficient funds for gas * price + value: balance 0, tx cost 3000000000000000
```

**Solution:** The setup script uses a hardcoded private key that needs funds. Either:

**Option 1: Fund the hardcoded address** (if using a local devnet):
```shell
# The script uses this private key by default
# Address: 0xC951181A1BC142Cf9d162C18f2233ea09931e6EA
# Private key: 815405dddb0e2a99b12af775fd2929e526704e1d1aea6a0b4e74dc33e2f7fcd2

# Fund it from your genesis/pre-funded account using cast (foundry)
cast send 0xC951181A1BC142Cf9d162C18f2233ea09931e6EA \
  --value 1000ether \
  --private-key <your_genesis_funded_private_key> \
  --rpc-url http://localhost:8123
```

**Option 2: Edit the script** to use your own funded private key:
```shell
nano 1-setup.sh
# Replace the -s parameter value with your private key
```

**Option 3: Run manually** with your own private key:
```shell
adventure evm bench erc20-init 100000000000000000000 \
  -i http://localhost:8123 \
  -a ./config/devnet/addr_20000_wmt \
  -s <your_funded_private_key>
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

### Binary not found in PATH

If you get `command not found: adventure`:

**Solution:**
```shell
# Check where it's installed
echo $GOPATH/bin

# Add to PATH
export PATH=$PATH:$(go env GOPATH)/bin

# Or use full path
$GOPATH/bin/adventure evm bench transfer -i http://localhost:8123 -c 100
```

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
curl -X POST http://localhost:8123 -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

---

## Complete Example Workflow

Here's a complete end-to-end example for stress testing a local sequencer:

### Scenario: Testing Local OP Stack Sequencer

**Step 1: Compile the tool**
```shell
make
export PATH=$PATH:$(go env GOPATH)/bin
```

**Step 2: Verify RPC is accessible**
```shell
curl -X POST http://localhost:8123 -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

**Step 3: Fund test accounts**
```shell
# Get a funded private key from your genesis config
adventure evm batch-transfer 100 -i http://localhost:8123 -s <your_funded_private_key>
```

**Step 4: Run baseline test (5 minutes)**
```shell
adventure evm bench transfer -i http://localhost:8123 -c 10 -t 1000
# Monitor for 5 minutes, then Ctrl+C
```

**Step 5: Increase load gradually**
```shell
# Medium load (5 minutes)
adventure evm bench transfer -i http://localhost:8123 -c 100 -t 100
# Ctrl+C after 5 minutes

# High load (5 minutes)
adventure evm bench transfer -i http://localhost:8123 -c 500 -t 0
# Ctrl+C after 5 minutes
```

**Step 6: Test query performance**
```shell
adventure evm bench query -i http://localhost:8123 -t 1000 -o 10,10,10,10,10,10,10,10,10
# Run for 5 minutes, then Ctrl+C
```

**Step 7: Check transaction status**
```shell
./check_random_tx.sh
```

**Step 8: Check mempool**
```shell
./txpool.sh
```

### Scenario: Testing with ERC20 Tokens

**Complete automated workflow:**
```shell
# 1. Setup ERC20 contract and fund accounts
./1-setup.sh

# 2. Run ERC20 stress test
./2-bench-erc20.sh
# Let run for 10 minutes, then Ctrl+C

# 3. Run native transfer test
./3-bench-native.sh
# Let run for 10 minutes, then Ctrl+C

# 4. Check transaction status
./check_random_tx.sh

# 5. Check mempool
./txpool.sh
```

### Scenario: DeFi Protocol Testing

```shell
# 1. Initialize multi-contract DeFi setup
./10-setup-wmt.sh

# 2. Run multi-contract DeFi stress test
./11-wmt.sh
# Let run for 15 minutes, then Ctrl+C

# 3. Check balances
adventure evm bench multiwmt-token -f config/poly_test/poly_multi_wmt-cList_5.json
```

---

## Summary

The Adventure tool provides comprehensive stress testing capabilities:

- **10+ stress test types** for different workload patterns
- **3 execution modes**: CLI flags, config files, or helper scripts
- **Built-in monitoring** scripts for transaction status and mempool
- **Flexible account management** with 2000 built-in accounts or custom sets
- **Reproducible tests** via JSON configuration files
- **Automated workflows** via shell scripts

**Key takeaways:**
1. Always fund accounts before testing
2. Start with low concurrency and increase gradually
3. Monitor system resources during tests
4. Use scripts for common workflows
5. Tests run indefinitely - use Ctrl+C to stop
6. For OP Stack, send to op-geth (port 8545), not op-node

For questions or issues, refer to the specific command documentation above or check the codebase at `/Users/siewvuichee/Desktop/git-repos/adventure`.
