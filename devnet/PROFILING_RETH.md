# Op-Reth Profiling Guide

This guide explains how to profile op-reth in the local development environment using `perf` for CPU profiling and flamegraph generation.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
  - [1. Enable Profiling in Configuration](#1-enable-profiling-in-configuration)
  - [2. Build and Start the Environment](#2-build-and-start-the-environment)
  - [3. Collect a CPU Profile](#3-collect-a-cpu-profile)
- [Detailed Usage](#detailed-usage)
  - [Available Scripts](#available-scripts)
  - [Building Op-Reth with Profiling Support](#building-op-reth-with-profiling-support)
- [Analyzing Profiles](#analyzing-profiles)
  - [Understanding Flamegraphs](#understanding-flamegraphs)
  - [Common Profiling Scenarios](#common-profiling-scenarios)
    - [1. Finding CPU Hotspots](#1-finding-cpu-hotspots)
    - [2. Analyzing Block Processing](#2-analyzing-block-processing)
    - [3. Comparing Performance](#3-comparing-performance)
    - [4. Profiling Under Load](#4-profiling-under-load)
    - [5. Stress Testing with Adventure Tool](#5-stress-testing-with-adventure-tool)
- [Profiling Data](#profiling-data)
  - [Storage](#storage)
  - [File Sizes](#file-sizes)
  - [Cleanup](#cleanup)
- [Configuration Options](#configuration-options)
  - [Docker Compose Settings](#docker-compose-settings)
  - [Perf Sampling Rate](#perf-sampling-rate)
- [Platform-Specific Notes](#platform-specific-notes)
  - [macOS (M1/M2/M3)](#macos-m1m2m3)
  - [Linux](#linux)
  - [Windows](#windows)
- [Troubleshooting](#troubleshooting)
- [Advanced Usage](#advanced-usage)
  - [Custom Flamegraph Options](#custom-flamegraph-options)
  - [Profiling Specific Operations](#profiling-specific-operations)
  - [Using perf report (Alternative View)](#using-perf-report-alternative-view)
- [Resources](#resources)
- [Support](#support)

## Overview

The profiling setup uses [Linux perf](https://perf.wiki.kernel.org/) for CPU profiling with full debug symbol support. Profiles are visualized using interactive [flamegraphs](https://www.brendangregg.com/flamegraphs.html) that can be viewed in any web browser.

**Why perf?**
- ✅ Full function name symbolication (no hex addresses)
- ✅ Works offline without symbol servers
- ✅ Generates self-contained SVG flamegraphs
- ✅ Better integration with debug symbols
- ✅ Standard Linux profiling tool

## Prerequisites

- Docker and Docker Compose
- Op-reth source code (if building with profiling support)
- macOS, Linux, or Windows WSL2

## Quick Start

### 1. Enable Profiling in Configuration

Edit your `.env` file:

```bash
# Be sure to enable reth
SEQ_TYPE=reth

# Profiling configuration for op-reth
RETH_PROFILING_ENABLED=true

# To build reth (init.sh)
SKIP_OP_RETH_BUILD=false

# Depending on which service you want to capture perf.
SEQ_TYPE=reth
RPC_TYPE=reth

# Set your reth source directory (if building from source)
OP_RETH_LOCAL_DIRECTORY=/path/to/your/reth
```

### 2. Build and Start the Environment

```bash
cd test
# This will build op-reth with debug symbols and perf pre-installed
./init.sh

# Start the environment
./0-all.sh
```

### 3. Collect a CPU Profile

```bash
# Profile for 60 seconds (default)
./scripts/profile-reth-perf.sh op-reth-seq 60

# Profile for 30 seconds
./scripts/profile-reth-perf.sh op-reth-seq 30
```

## Detailed Usage

### Available Scripts

#### `profile-reth-perf.sh`

Captures a CPU profile using perf with full debug symbols.

```bash
./scripts/profile-reth-perf.sh [container_name] [duration_seconds]
```

**Output:**
- `./profiling/[container_name]/perf-TIMESTAMP.data` - Raw perf data
- `./profiling/[container_name]/perf-TIMESTAMP.script` - Symbolicated stack traces

#### `generate-flamegraph.sh`

Generates an interactive SVG flamegraph from perf data.

```bash
./scripts/generate-flamegraph.sh [container_name] [perf_script_file]
```

**Examples:**
```bash
# Generate flamegraph from perf script
./scripts/generate-flamegraph.sh op-reth-seq perf-20241117-143022.script

# The output will be: ./profiling/op-reth-seq/perf-20241117-143022.svg
```

**Flamegraph Features:**
- **Interactive**: Click to zoom, hover for details
- **Self-contained**: No external dependencies
- **Searchable**: Ctrl+F to find functions
- **Color-coded**: Visual distinction of code areas

### Building Op-Reth with Profiling Support

The profiling-enabled image includes:
- **Release optimizations** - Fast performance
- **Debug symbols (debuginfo=2)** - Full function names and line numbers
- **Frame pointers** - Accurate stack traces
- **Perf pre-installed** - Ready for CPU profiling

**Build command:**
```bash
# Set your reth source directory in .env or export it
export OP_RETH_LOCAL_DIRECTORY=/path/to/your/reth

# Build profiling-enabled image
./scripts/build-reth-with-profiling.sh
```

## Analyzing Profiles

### Understanding Flamegraphs

Flamegraphs visualize where CPU time is spent:

- **Width** = CPU time (wider = more time spent)
- **Height** = Call stack depth (top = leaf functions, bottom = root)
- **Color** = Visual distinction (not meaningful for perf)

**Reading the graph:**
1. The bottom shows the entry point (usually `main` or thread start)
2. Each box above represents a function call
3. Wide boxes are CPU hotspots
4. Tall stacks show deep call chains

**Interactive features:**
- **Click** any box to zoom in and focus on that subtree
- **Hover** to see full function name and percentage
- **Search** (Ctrl+F) to highlight specific functions
- **Reset Zoom** to return to full view

### Common Profiling Scenarios

#### 1. Finding CPU Hotspots

1. Collect profile during active operation:
   ```bash
   ./scripts/profile-reth-perf.sh op-reth-seq 60
   ```
2. Generate flamegraph:
   ```bash
   ./scripts/generate-flamegraph.sh op-reth-seq perf-TIMESTAMP.script
   ```
3. Look for wide boxes - these are your hotspots
4. Click to zoom and examine the call stack

#### 2. Analyzing Block Processing

1. Send transactions or wait for block activity
2. Profile during active processing:
   ```bash
   ./scripts/profile-reth-perf.sh op-reth-seq 30
   ```
3. Generate flamegraph and look for:
   - `reth_*` functions (Reth-specific code)
   - `tokio::*` functions (Async runtime)
   - Wide bars in execution/validation code

#### 3. Comparing Performance

```bash
# Before optimization
./scripts/profile-reth-perf.sh op-reth-seq 60
./scripts/generate-flamegraph.sh op-reth-seq perf-TIMESTAMP1.script

# Make changes, restart

# After optimization
./scripts/profile-reth-perf.sh op-reth-seq 60
./scripts/generate-flamegraph.sh op-reth-seq perf-TIMESTAMP2.script

# Compare the two SVG files side-by-side
```

#### 4. Profiling Under Load

For meaningful profiles, op-reth should be actively processing:

```bash
# Terminal 1: Send transactions to generate load
cast send --rpc-url http://localhost:8123 ...

# Terminal 2: Profile during load
./scripts/profile-reth-perf.sh op-reth-seq 60
```

**Note:** Idle systems will show very few samples. Look for output like:
```
[ perf record: Captured and wrote 0.235 MB perf.data (1000+ samples) ]
```
More samples = better data.

### 5. Stress Testing with Adventure Tool

For comprehensive profiling, use the [Adventure tool](https://github.com/cuiweixie/adventure/tree/leo/contract-deploy) to generate realistic load while profiling.

#### Why Stress Test During Profiling?

- **Realistic Workloads**: Captures CPU hotspots under actual transaction load
- **Meaningful Data**: Idle systems show very few samples; active systems reveal bottlenecks
- **Identify Bottlenecks**: High concurrency exposes performance issues that don't appear under light load
- **Compare Scenarios**: Different workload types (transfers, contracts, queries) stress different code paths

#### Prerequisites

1. **Build Adventure tool**:
   ```bash
   cd /path/to/adventure
   make
   export PATH=$PATH:$(go env GOPATH)/bin
   ```

2. **Fund test accounts** (Adventure has 2000 built-in accounts):
   ```bash
   # Fund built-in accounts (requires a funded private key from genesis)
   adventure evm batch-transfer 10 -i http://localhost:8123 -s <funded_private_key>
   ```

For detailed Adventure setup and usage, see [STRESS_TEST_GUIDE.md](./STRESS_TEST_GUIDE.md).

#### Workflow: Stress Test + Profile

**Basic Pattern:**
```bash
# Terminal 1: Start stress test
adventure evm bench transfer -i http://localhost:8123 -c 200 -t 0

# Terminal 2: Profile during stress test (after a few seconds)
./scripts/profile-reth-perf.sh op-reth-seq 60

# Terminal 1: Stop stress test after profiling completes (Ctrl+C)
```

#### Example Scenarios

##### Scenario 1: Native Transfer Workload
Test transaction processing throughput:

```bash
# Terminal 1: High-throughput transfer stress
adventure evm bench transfer -i http://localhost:8123 -c 500 -t 0

# Terminal 2: Profile for 60 seconds
./scripts/profile-reth-perf.sh op-reth-seq 60

# After profiling completes, stop stress test (Ctrl+C in Terminal 1)
```

**What to look for in flamegraph:**
- Transaction validation hotspots
- Signature verification
- State database writes
- Nonce management overhead

##### Scenario 2: Contract Execution Workload
Test EVM and contract execution performance:

```bash
# Prerequisites: Deploy test contracts first
# See STRESS_TEST_GUIDE.md for contract deployment

# Terminal 1: Contract operation stress
adventure evm bench operate -i http://localhost:8123 -c 100 \
  --opts 10,10,10,10,10 --times 100 --contract 0x... --id 0

# Terminal 2: Profile for 90 seconds
./scripts/profile-reth-perf.sh op-reth-seq 90
```

**What to look for in flamegraph:**
- EVM execution time
- Storage operations (SSTORE/SLOAD)
- Contract bytecode interpretation
- Gas calculation overhead

##### Scenario 3: ERC20 Token Workload
Test token transfer performance:

```bash
# Prerequisites: Deploy and fund ERC20 accounts
./1-setup.sh  # Helper script from Adventure (see STRESS_TEST_GUIDE.md)

# Terminal 1: ERC20 stress test
./2-bench-erc20.sh

# Terminal 2: Profile for 60 seconds
./scripts/profile-reth-perf.sh op-reth-seq 60

# Terminal 1: Stop stress test (Ctrl+C)
```

**What to look for in flamegraph:**
- Contract call overhead vs native transfers
- Storage access patterns for balances
- Event emission costs

##### Scenario 4: Mixed Read/Write Workload
Test combined query and transaction load:

```bash
# Terminal 1: Transaction load
adventure evm bench transfer -i http://localhost:8123 -c 200 -t 0

# Terminal 2: Query load
adventure evm bench query -i http://localhost:8123 -t 500 -o 10,10,10,10,10,10,10,10,10

# Terminal 3: Profile for 120 seconds
./scripts/profile-reth-perf.sh op-reth-seq 120

# Stop both stress tests (Ctrl+C in Terminals 1 and 2)
```

**What to look for in flamegraph:**
- Resource contention between read and write paths
- RPC handler overhead
- Database query performance
- Lock contention

##### Scenario 5: DeFi Protocol Workload
Test complex multi-contract interactions:

```bash
# Prerequisites: Initialize multi-WMT setup
./10-setup-wmt.sh  # Helper script from Adventure

# Terminal 1: Multi-contract DeFi stress
./11-wmt.sh

# Terminal 2: Profile for 120 seconds
./scripts/profile-reth-perf.sh op-reth-seq 120

# Terminal 1: Stop stress test (Ctrl+C)
```

**What to look for in flamegraph:**
- Complex transaction execution paths
- Multiple contract interaction overhead
- Token approval/transfer costs

#### Advanced: Automated Profile Collection

Create a script to automate stress testing with profiling:

```bash
#!/bin/bash
# profile-under-load.sh

WORKLOAD_TYPE=${1:-transfer}  # transfer, erc20, query, etc.
DURATION=${2:-60}

echo "Starting stress test: $WORKLOAD_TYPE"

# Start stress test in background
case $WORKLOAD_TYPE in
  transfer)
    adventure evm bench transfer -i http://localhost:8123 -c 200 -t 0 &
    ;;
  erc20)
    ./2-bench-erc20.sh &
    ;;
  query)
    adventure evm bench query -i http://localhost:8123 -t 500 -o 10,10,10,10,10,10,10,10,10 &
    ;;
  *)
    echo "Unknown workload type: $WORKLOAD_TYPE"
    exit 1
    ;;
esac

STRESS_PID=$!
echo "Stress test started (PID: $STRESS_PID)"

# Wait for workload to ramp up
echo "Waiting 10 seconds for workload to ramp up..."
sleep 10

# Profile
echo "Starting profiling for ${DURATION}s..."
./scripts/profile-reth-perf.sh op-reth-seq $DURATION

# Stop stress test
echo "Stopping stress test..."
kill $STRESS_PID
wait $STRESS_PID 2>/dev/null

echo "Profile collection complete!"
echo "Flamegraph: ./profiling/op-reth-seq/perf-*.svg"
```

Usage:
```bash
chmod +x profile-under-load.sh

# Profile transfer workload
./profile-under-load.sh transfer 60

# Profile ERC20 workload
./profile-under-load.sh erc20 90

# Profile query workload
./profile-under-load.sh query 60
```

#### Comparing Profiles Across Workloads

To identify which operations are most expensive:

```bash
# Collect profiles for different workloads
./profile-under-load.sh transfer 60
./profile-under-load.sh erc20 60
./profile-under-load.sh query 60

# Compare the generated flamegraphs side-by-side
# Look for:
# - Which workload type shows widest bars (most CPU time)
# - Different hotspots per workload
# - Common bottlenecks across all workloads
```

#### Tips for Profiling Under Stress

1. **Ramp-up time**: Wait 5-10 seconds after starting stress test before profiling
2. **Sufficient duration**: Profile for at least 60 seconds to capture enough samples
3. **Consistent load**: Use `-t 0` (no sleep) for maximum, consistent load
4. **Multiple runs**: Collect 2-3 profiles per workload type for consistency
5. **Monitor system**: Check `docker stats` to ensure system isn't overloaded
6. **Check samples**: Verify you collected 1000+ samples in perf output

#### Troubleshooting

**Problem: Very few samples despite stress test**
```bash
# Check if stress test is actually running
docker stats op-reth-seq  # Should show significant CPU usage

# Check stress test output for errors
# Common: insufficient funds, invalid nonce
```

**Problem: Stress test stops immediately**
```bash
# Ensure accounts are funded
adventure evm batch-transfer 10 -i http://localhost:8123 -s <funded_private_key>

# Verify RPC is accessible
curl -X POST http://localhost:8123 -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

**Problem: System becomes unresponsive**
```bash
# Reduce stress test concurrency
adventure evm bench transfer -i http://localhost:8123 -c 50 -t 100  # Lower concurrency, add sleep
```

For more Adventure tool usage and troubleshooting, see [STRESS_TEST_GUIDE.md](./STRESS_TEST_GUIDE.md).

## Profiling Data

### Storage

Profiles are stored in:
```
test/profiling/
├── op-reth-seq/
│   ├── perf-20241117-143022.data      # Raw perf data
│   ├── perf-20241117-143022.script    # Symbolicated output
│   ├── perf-20241117-143022.folded    # Folded stacks
│   ├── perf-20241117-143022.svg       # Flamegraph (view in browser)
│   └── ...
├── op-reth-rpc/
│   └── ...
└── FlameGraph/                         # Flamegraph tools (cloned once)
```

### File Sizes

Typical profile sizes:
- **perf.data**: 0.1-5 MB (raw perf data)
- **perf.script**: 1-50 MB (symbolicated stacks)
- **flamegraph SVG**: 10-200 KB (compressed, interactive)

### Cleanup

```bash
# Remove old profiles
rm -rf test/profiling/op-reth-seq/perf-*

# Keep only recent profiles (last 7 days)
find test/profiling -name "perf-*" -mtime +7 -delete

# Clean up FlameGraph tools (will be re-downloaded if needed)
rm -rf test/profiling/FlameGraph
```

## Configuration Options

### Docker Compose Settings

For profiling, the following capabilities are enabled in `docker-compose.yml`:

```yaml
privileged: true
cap_add:
  - SYS_ADMIN
  - SYS_PTRACE
security_opt:
  - seccomp=unconfined
```

These allow perf to access performance monitoring capabilities.

### Perf Sampling Rate

Default: 999 Hz (999 samples per second)

To change, edit `scripts/profile-reth-perf.sh`:
```bash
perf record -F 1000 -p $RETH_PID ...  # 1000 Hz
```

Higher rates = more detail but larger files.

## Platform-Specific Notes

### macOS (M1/M2/M3)

- ✅ Fully supported via Docker Desktop
- ✅ ARM64 native performance
- ✅ Perf works in Linux containers
- ✅ Flamegraphs viewable in Safari/Chrome
- ℹ️ Profiling happens inside the Linux container

### Linux

- ✅ Native support
- ✅ Best performance
- ✅ All profiling features available
- ✅ Direct access to perf

### Windows

- ✅ Supported via WSL2
- ℹ️ Use WSL2 Linux distribution
- ✅ Flamegraphs viewable in browser

## Troubleshooting

### "perf: command not found"

Perf should be pre-installed in the profiling image. Check:
```bash
docker exec op-reth-seq which perf
docker exec op-reth-seq perf --version
```

If missing, the container may not be using the profiling-enabled image.

### "Error: Could not find op-reth process"

Check if the container is running:
```bash
docker ps | grep reth
docker exec op-reth-seq pgrep -f "op-reth node"
```

### "Permission denied" errors

Ensure the container has profiling capabilities:
```bash
docker inspect op-reth-seq | grep -i privileged
```

Should show: `"Privileged": true`

### No function names (hex addresses)

This means debug symbols are missing. Verify:
```bash
docker exec op-reth-seq file /usr/local/bin/op-reth
```

Should show: `with debug_info, not stripped`

If symbols are missing, rebuild with:
```bash
./scripts/build-reth-with-profiling.sh
```

### Very few samples collected

Op-reth may be idle. Check CPU usage:
```bash
docker stats op-reth-seq
```

For better profiles:
1. Generate load (send transactions)
2. Profile during active block processing
3. Increase profiling duration (60-120 seconds)

### "addr2line: not found" warnings

These are non-critical warnings. Function names will still appear in the flamegraph. To fix:
```bash
# Add binutils to the Dockerfile if desired
RUN apt-get install -y binutils
```

### Flamegraph shows black bars

This was fixed in the latest version. If you still see black bars:
1. Regenerate with: `./scripts/generate-flamegraph.sh ...`
2. Check that perf.script has content: `head -50 ./profiling/op-reth-seq/perf-*.script`
3. Ensure op-reth was active during profiling

## Advanced Usage

### Custom Flamegraph Options

Edit `scripts/generate-flamegraph.sh` to customize:

```bash
flamegraph.pl \
    --title "Custom Title" \
    --width 2400 \            # Wider graph
    --fontsize 16 \           # Larger text
    --colors hot \            # Color scheme
    --inverted \              # Reverse (icicle graph)
    input.folded > output.svg
```

### Profiling Specific Operations

```bash
# Start profiling just before operation
./scripts/profile-reth-perf.sh op-reth-seq 30 &
PROF_PID=$!

# Trigger operation
cast send --rpc-url http://localhost:8123 ...

# Wait for profiling to complete
wait $PROF_PID

# Generate flamegraph
./scripts/generate-flamegraph.sh op-reth-seq perf-*.script
```

### Using perf report (Alternative View)

View in terminal using perf's built-in TUI:

```bash
# Copy perf.data to container (if not already there)
docker cp ./profiling/op-reth-seq/perf-TIMESTAMP.data op-reth-seq:/tmp/perf.data

# View interactive report
docker exec -it op-reth-seq perf report -i /tmp/perf.data

# Or generate text report
docker exec op-reth-seq perf report -i /tmp/perf.data --stdio
```

## Resources

- [Linux Perf](https://perf.wiki.kernel.org/)
- [Brendan Gregg's Flamegraphs](https://www.brendangregg.com/flamegraphs.html)
- [FlameGraph GitHub](https://github.com/brendangregg/FlameGraph)
- [Rust Performance Book](https://nnethercote.github.io/perf-book/profiling.html)
- [Reth Documentation](https://reth.rs)

## Support

For issues or questions:
1. Check container logs: `docker logs op-reth-seq`
2. Verify perf installation: `docker exec op-reth-seq perf --version`
3. Check debug symbols: `docker exec op-reth-seq file /usr/local/bin/op-reth`
4. Review this guide's troubleshooting section
5. Check [perf documentation](https://perf.wiki.kernel.org/)
