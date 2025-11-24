# Op-Reth Profiling Guide

This guide explains how to profile op-reth in the local development environment using `perf` for CPU profiling and various tools for memory profiling, with interactive flamegraph generation.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
  - [1. Enable Profiling in Configuration](#1-enable-profiling-in-configuration)
  - [2. Build and Start the Environment](#2-build-and-start-the-environment)
  - [3. Collect a CPU Profile](#3-collect-a-cpu-profile)
  - [4. Collect a Memory Profile](#4-collect-a-memory-profile)
- [Detailed Usage](#detailed-usage)
  - [Available Scripts](#available-scripts)
  - [Building Op-Reth with Profiling Support](#building-op-reth-with-profiling-support)
- [CPU Profiling](#cpu-profiling)
- [Memory Profiling](#memory-profiling)
  - [Quick Memory Profiling](#quick-memory-profiling)
  - [Memory Profiling Methods](#memory-profiling-methods)
  - [When to Use Memory Profiling](#when-to-use-memory-profiling)
- [Analyzing Profiles](#analyzing-profiles)
  - [Understanding Flamegraphs](#understanding-flamegraphs)
  - [Common Profiling Scenarios](#common-profiling-scenarios)
    - [1. Finding CPU Hotspots](#1-finding-cpu-hotspots)
    - [2. Analyzing Block Processing](#2-analyzing-block-processing)
    - [3. Comparing Performance](#3-comparing-performance)
    - [4. Profiling Under Load](#4-profiling-under-load)
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

## Overview

The profiling setup provides comprehensive performance analysis tools:

**CPU Profiling** uses [Linux perf](https://perf.wiki.kernel.org/) with full debug symbol support to identify compute bottlenecks.

**Memory Profiling** uses multiple tools ([heaptrack](https://github.com/KDE/heaptrack), jemalloc, valgrind) to identify memory leaks, excessive allocations, and memory bloat.

All profiles are visualized using interactive [flamegraphs](https://www.brendangregg.com/flamegraphs.html) that can be viewed in any web browser.

**Key Features:**
- ✅ Full function name symbolication (no hex addresses)
- ✅ Works offline without symbol servers
- ✅ Generates self-contained SVG flamegraphs
- ✅ Better integration with debug symbols
- ✅ Multiple profiling methods for different use cases
- ✅ Low overhead suitable for development and production

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

# Enable jemalloc heap profiling (for memory profiling)
JEMALLOC_PROFILING=true

# To build reth (init.sh)
SKIP_OP_RETH_BUILD=false

# Depending on which service you want to capture perf.
SEQ_TYPE=reth
RPC_TYPE=reth

# Set your reth source directory (if building from source)
OP_RETH_LOCAL_DIRECTORY=/path/to/your/reth
```

**Note:** `JEMALLOC_PROFILING=true` enables jemalloc heap profiling. The entrypoint scripts automatically configure `_RJEM_MALLOC_CONF` for tikv-jemalloc.

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

### 4. Collect a Memory Profile

```bash
# Jemalloc profiling (low overhead, works in development & production)
./scripts/profile-reth-jemalloc.sh op-reth-seq 60

# Generate flamegraph from heap dumps
./scripts/generate-memory-flamegraph.sh op-reth-seq latest
```

All profiles generate interactive flamegraphs in `./profiling/op-reth-seq/`:
- CPU profiles: `perf-*.svg`
- Memory profiles: `*-allocations-demangled.svg`

## Detailed Usage

### Available Scripts

#### CPU Profiling Scripts

**`profile-reth-perf.sh`** - CPU profiling

Captures a CPU profile using perf with full debug symbols.

```bash
./scripts/profile-reth-perf.sh [container_name] [duration_seconds]
```

**Output:**
- `./profiling/[container_name]/perf-TIMESTAMP.data` - Raw perf data
- `./profiling/[container_name]/perf-TIMESTAMP.script` - Symbolicated stack traces
- `./profiling/[container_name]/perf-TIMESTAMP.svg` - CPU flamegraph

**`profile-reth-offcpu.sh`** - Off-CPU profiling

Captures blocking/waiting time to identify I/O bottlenecks and lock contention.

```bash
./scripts/profile-reth-offcpu.sh [container_name] [duration_seconds]
```

See [OFFCPU_PROFILING.md](OFFCPU_PROFILING.md) for details.

#### Memory Profiling Scripts

**`profile-reth-jemalloc.sh`** - Jemalloc heap profiling

Uses jemalloc's built-in profiling. Very low overhead, suitable for development and production.

**Prerequisites:** Enable jemalloc profiling in docker-compose.yml:
```yaml
environment:
  - JEMALLOC_PROFILING=true
```

```bash
./scripts/profile-reth-jemalloc.sh [container_name] [duration_seconds]
```

**Output:**
- `./profiling/[container_name]/jeprof.*.heap` - Heap dump files
- `./profiling/[container_name]/jemalloc-TIMESTAMP.txt` - Text report

**Note:** Reth uses tikv-jemalloc which requires `_RJEM_MALLOC_CONF` (not `MALLOC_CONF`). The entrypoint scripts handle this automatically when `JEMALLOC_PROFILING=true`.

See [MEMORY_PROFILING.md](MEMORY_PROFILING.md) for complete memory profiling guide.

#### Flamegraph Generation

**`generate-flamegraph.sh`** - CPU flamegraphs

Generates an interactive SVG flamegraph from CPU perf data.

```bash
./scripts/generate-flamegraph.sh [container_name] [perf_script_file]
```

**`generate-memory-flamegraph.sh`** - Memory flamegraphs

Generates an interactive SVG flamegraph from memory profiling data with automatic symbol demangling.

```bash
./scripts/generate-memory-flamegraph.sh [container_name] [input_file] [profile_type]
```

**Input file options:**
- `all` - Merge all .heap files (default)
- `latest` - Use only the latest .heap file
- `last:N` - Merge the last N .heap files (e.g., `last:5`)
- `file1,file2` - Comma-separated list of specific files
- `filename` - Single file (e.g., `jeprof.1.0.m0.heap`)

**Examples:**
```bash
# Generate flamegraph from all heap files (merged)
./scripts/generate-memory-flamegraph.sh op-reth-seq all

# Generate flamegraph from latest heap file
./scripts/generate-memory-flamegraph.sh op-reth-seq latest

# Generate flamegraph from last 5 heap files
./scripts/generate-memory-flamegraph.sh op-reth-seq last:5

# The output will be: ./profiling/op-reth-seq/<basename>-allocations-demangled.svg
```

**Features:**
- Automatic symbol resolution using `nm`
- Rust symbol demangling via `rustfilt` or `c++filt`
- Readable function names in the flamegraph

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
- **CPU profiling tools** - perf for multiple kernel versions
- **Memory profiling tools** - heaptrack, valgrind, jemalloc profiling
- **Visualization tools** - FlameGraph, graphviz

**Build command:**
```bash
# Set your reth source directory in .env or export it
export OP_RETH_LOCAL_DIRECTORY=/path/to/your/reth

# Build profiling-enabled image (includes both CPU and memory profiling tools)
./scripts/build-reth-with-profiling.sh
```

## CPU Profiling

CPU profiling identifies where your code spends compute time. Use this to find:
- Hot functions (functions consuming most CPU time)
- Inefficient algorithms
- Unexpected computation bottlenecks

**Quick Start:**
```bash
# Profile for 60 seconds
./scripts/profile-reth-perf.sh op-reth-seq 60

# View the flamegraph
open ./profiling/op-reth-seq/perf-*.svg
```

**What to look for in CPU flamegraphs:**
- **Wide bars** = Functions using most CPU time (optimize these first)
- **Tall stacks** = Deep call chains (may indicate recursion or complex logic)
- **Unexpected functions** = Code paths you didn't expect to be hot

For detailed CPU profiling information, see the sections below on [Analyzing Profiles](#analyzing-profiles) and [Common Profiling Scenarios](#common-profiling-scenarios).

For off-CPU profiling (blocking, I/O, locks), see [OFFCPU_PROFILING.md](OFFCPU_PROFILING.md).

## Memory Profiling

Memory profiling identifies how your code allocates and uses memory. Use this to find:
- Memory leaks (allocations never freed)
- Excessive allocations (allocation hotspots)
- Memory bloat (using more memory than necessary)
- Peak memory usage

### Quick Memory Profiling

```bash
# Jemalloc profiling (works for development & production)
./scripts/profile-reth-jemalloc.sh op-reth-seq 60

# Generate flamegraph from heap dumps
./scripts/generate-memory-flamegraph.sh op-reth-seq latest

# View the memory flamegraph
open ./profiling/op-reth-seq/*-allocations-demangled.svg
```

### When to Use Memory Profiling

Use memory profiling when you observe:
- ❌ **High memory usage** - RSS/memory consumption higher than expected
- ❌ **Memory growth** - Memory usage continuously increasing over time
- ❌ **OOM errors** - Out of memory crashes
- ❌ **Slow allocations** - High CPU time in allocator functions
- ❌ **Fragmentation** - Memory not released back to OS

**What to look for in memory flamegraphs:**
- **Wide bars** = Functions allocating most memory (bytes allocated)
- **Unexpected allocators** = Memory allocated in surprising places
- **Temporary allocations** = Short-lived objects that could be pooled

For complete memory profiling documentation, see [MEMORY_PROFILING.md](MEMORY_PROFILING.md).

### Combining CPU and Memory Profiling

For comprehensive performance analysis, run both:

```bash
# Run both in parallel
./scripts/profile-reth-perf.sh op-reth-seq 60 &
./scripts/profile-reth-jemalloc.sh op-reth-seq 60 &
wait

# Generate memory flamegraph
./scripts/generate-memory-flamegraph.sh op-reth-seq latest

# Compare results
ls -lht ./profiling/op-reth-seq/*.svg
```

**Analysis matrix:**

| CPU Usage | Memory Usage | Likely Issue |
|-----------|--------------|--------------|
| High | Low | CPU-bound (optimize algorithms) |
| Low | High | Memory-bound (optimize allocations) |
| High | High | Both (profile both!) |
| Low | Low | I/O-bound (use off-CPU profiling) |

## Analyzing Profiles

### Understanding Flamegraphs

Flamegraphs visualize resource consumption in your code. The interpretation differs slightly for CPU vs memory:

#### CPU Flamegraphs

- **Width** = CPU time (wider = more time spent)
- **Height** = Call stack depth (top = leaf functions, bottom = root)
- **Color** = Visual distinction (not meaningful for perf)

**Reading CPU flamegraphs:**
1. The bottom shows the entry point (usually `main` or thread start)
2. Each box above represents a function call
3. Wide boxes are CPU hotspots (optimize these!)
4. Tall stacks show deep call chains

#### Memory Flamegraphs

- **Width** = Memory allocated (wider = more bytes allocated)
- **Height** = Call stack depth showing allocation path
- **Color** = Visual distinction

**Reading memory flamegraphs:**
1. The bottom shows the entry point
2. Each box shows the allocation call path
3. Wide boxes are allocation hotspots (most bytes)
4. Focus on wide bars to reduce memory usage

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

## Profiling Data

### Storage

Profiles are stored in:
```
profiling/
├── op-reth-seq/
│   ├── perf-20241117-143022.data             # Raw CPU perf data
│   ├── perf-20241117-143022.script           # Symbolicated CPU output
│   ├── perf-20241117-143022.folded           # Folded CPU stacks
│   ├── perf-20241117-143022.svg              # CPU flamegraph
│   ├── offcpu-20241117-143022.data           # Off-CPU data
│   ├── offcpu-20241117-143022.svg            # Off-CPU flamegraph
│   ├── jeprof.1.0.m0.heap                    # Jemalloc heap dump
│   ├── jemalloc-20241117-143022.txt          # Jemalloc text report
│   ├── merged-20241117-143022.folded         # Folded stacks (raw)
│   ├── merged-20241117-143022.demangled.folded    # Folded stacks (demangled)
│   ├── merged-20241117-143022-allocations-demangled.svg  # Jemalloc flamegraph
│   └── ...
├── op-reth-rpc/
│   └── ...
└── FlameGraph/                                # Flamegraph tools (cloned once)
```

### File Sizes

Typical profile sizes:

**CPU Profiles:**
- **perf.data**: 0.1-5 MB (raw perf data)
- **perf.script**: 1-50 MB (symbolicated stacks)
- **perf SVG**: 10-200 KB (compressed, interactive flamegraph)

**Memory Profiles:**
- **jemalloc.heap**: 0.1-5 MB (heap dump)
- **jemalloc.txt**: 0.1-1 MB (text report)
- **memory SVG**: 10-200 KB (compressed, interactive flamegraph)

### Cleanup

```bash
# Remove old CPU profiles
rm -rf ./profiling/op-reth-seq/perf-*
rm -rf ./profiling/op-reth-seq/offcpu-*

# Remove old memory profiles
rm -rf ./profiling/op-reth-seq/jeprof.*
rm -rf ./profiling/op-reth-seq/jemalloc-*
rm -rf ./profiling/op-reth-seq/merged-*

# Keep only recent profiles (last 7 days)
find ./profiling -name "perf-*" -mtime +7 -delete
find ./profiling -name "jeprof.*" -mtime +7 -delete
find ./profiling -name "merged-*" -mtime +7 -delete

# Clean up FlameGraph tools (will be re-downloaded if needed)
rm -rf ./profiling/FlameGraph
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

### Documentation

- [MEMORY_PROFILING.md](MEMORY_PROFILING.md) - Complete memory profiling guide
- [OFFCPU_PROFILING.md](OFFCPU_PROFILING.md) - Off-CPU profiling guide

### CPU Profiling

- [Linux Perf](https://perf.wiki.kernel.org/)
- [Brendan Gregg's Flamegraphs](https://www.brendangregg.com/flamegraphs.html)
- [FlameGraph GitHub](https://github.com/brendangregg/FlameGraph)
- [Brendan Gregg's Perf Examples](https://www.brendangregg.com/perf.html)

### Memory Profiling

- [Jemalloc Profiling](https://github.com/jemalloc/jemalloc/wiki/Use-Case%3A-Heap-Profiling)

### General

- [Rust Performance Book](https://nnethercote.github.io/perf-book/profiling.html)
- [Reth Documentation](https://reth.rs)
