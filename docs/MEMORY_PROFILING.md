# Memory Profiling Guide for Reth

This guide explains how to profile memory usage in op-reth using jemalloc profiling.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Jemalloc Heap Profiling](#jemalloc-heap-profiling)
  - [Enable Profiling](#enable-profiling)
  - [Collecting Heap Dumps](#collecting-heap-dumps)
  - [Generating Flamegraphs](#generating-flamegraphs)
- [Live Memory Analysis](#live-memory-analysis)
- [Common Memory Issues](#common-memory-issues)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)

## Overview

Memory profiling helps identify:
- **Memory leaks**: Allocations that are never freed
- **Excessive allocations**: Hotspots creating too many objects
- **Memory bloat**: Unnecessary memory usage
- **Peak memory usage**: Maximum memory consumption
- **Allocation patterns**: Where and when memory is allocated

## Prerequisites

- Docker and Docker Compose
- Op-reth source code
- Memory profiling enabled container (built with `./scripts/build-reth-with-profiling.sh`)
- At least 4GB available RAM for profiling overhead

## Quick Start

### 1. Enable Memory Profiling in Configuration

Edit your `.env` file:

```bash
# Enable reth with memory profiling
SEQ_TYPE=reth
RETH_PROFILING_ENABLED=true
SKIP_OP_RETH_BUILD=false

# Set your reth source directory
OP_RETH_LOCAL_DIRECTORY=/path/to/your/reth
```

### 2. Build with Memory Profiling Support

```bash
# Build the profiling-enabled image
./scripts/build-reth-with-profiling.sh

# Start the environment
./init.sh
./0-all.sh
```

### 3. Run Memory Profiling

```bash
# Jemalloc profiling (production-ready, low overhead)
./scripts/profile-reth-jemalloc.sh op-reth-seq 60

# Generate flamegraph from heap dumps
./scripts/generate-memory-flamegraph.sh op-reth-seq latest
```

## Jemalloc Heap Profiling

Since reth is built with jemalloc, you can use its native profiling capabilities with minimal overhead.

### What Jemalloc Profiling Shows

- **Live allocations**: Current heap state
- **Allocation call stacks**: Where memory is allocated
- **Per-allocation-site statistics**: Bytes and counts
- **Heap dumps**: Snapshots at specific times

### Enable Profiling

Jemalloc profiling is controlled via environment variables. **Important:** Reth uses tikv-jemalloc which requires `_RJEM_MALLOC_CONF` (not `MALLOC_CONF`):

```bash
# Option 1: Use the JEMALLOC_PROFILING flag (recommended)
# Add to docker-compose.yml under op-reth-seq service:
environment:
  - JEMALLOC_PROFILING=true

# Option 2: Set _RJEM_MALLOC_CONF directly
# Add to docker-compose.yml under op-reth-seq service:
environment:
  - _RJEM_MALLOC_CONF=prof:true,prof_prefix:/profiling/jeprof,lg_prof_interval:30
```

**Options:**
- `prof:true` - Enable profiling
- `prof_prefix:<path>` - Output file prefix
- `lg_prof_interval:N` - Dump heap every 2^N bytes allocated
- `lg_prof_sample:N` - Sample rate (default: 19 = every 512KB)

**Note:** The entrypoint scripts (`reth-seq.sh`, `reth-rpc.sh`) automatically set `_RJEM_MALLOC_CONF` when `JEMALLOC_PROFILING=true`.

### Collecting Heap Dumps

```bash
# Start reth with jemalloc profiling enabled
./scripts/profile-reth-jemalloc.sh op-reth-seq 60
```

This will:
1. Enable jemalloc profiling
2. Collect heap dumps automatically
3. Generate text reports
4. Create allocation flamegraphs

### Generating Flamegraphs

```bash
# Generate flamegraph from all heap files (merged)
./scripts/generate-memory-flamegraph.sh op-reth-seq all

# Generate flamegraph from latest heap file only
./scripts/generate-memory-flamegraph.sh op-reth-seq latest

# Generate flamegraph from last N heap files
./scripts/generate-memory-flamegraph.sh op-reth-seq last:5

# Generate flamegraph from specific files (comma-separated)
./scripts/generate-memory-flamegraph.sh op-reth-seq jeprof.1.0.m0.heap,jeprof.1.1.i0.heap

# Generate flamegraph from a single heap file
./scripts/generate-memory-flamegraph.sh op-reth-seq jeprof.1.0.m0.heap
```

**Output:** `./profiling/op-reth-seq/<basename>-allocations-demangled.svg`

The script automatically:
- Resolves symbols using `nm` for fast lookup
- Demangles Rust symbols using `rustfilt` (preferred) or `c++filt`
- Cleans up remaining mangled symbol artifacts
- Generates an interactive SVG flamegraph with readable function names

### Manual Jemalloc Profiling

**Note:** Jemalloc profiling must be enabled at process startup. You cannot enable it for a running process.

```bash
# Restart container with profiling enabled
docker-compose stop op-reth-seq
# Add JEMALLOC_PROFILING=true to environment, then:
docker-compose up -d op-reth-seq

# Trigger manual heap dump using GDB (for tikv-jemalloc)
docker exec op-reth-seq sh -c '
  RETH_PID=$(pgrep -f "op-reth node" | head -1)
  gdb -batch -p $RETH_PID -ex "call (int)_rjem_mallctl(\"prof.dump\", 0, 0, 0, 0)" -ex quit
'

# List generated heap files
docker exec op-reth-seq ls -la /profiling/*.heap
```

**Generating reports from heap files:**
```bash
# Generate flamegraph (recommended)
./scripts/generate-memory-flamegraph.sh op-reth-seq latest

# Or generate text report manually
docker exec op-reth-seq cat /profiling/jeprof.*.heap | head -50
```

### Analyzing Jemalloc Output

The recommended way to analyze jemalloc heap dumps is using the flamegraph script:

```bash
# Generate demangled flamegraph (recommended)
./scripts/generate-memory-flamegraph.sh op-reth-seq latest

# View the flamegraph
open ./profiling/op-reth-seq/*-allocations-demangled.svg
```

**Note:** Traditional `jeprof`/`pprof` tools may not work with tikv-jemalloc's `heap_v2` format. The `generate-memory-flamegraph.sh` script handles this format correctly.

## Live Memory Analysis

For quick memory checks without heavy profiling:

### Using /proc/PID/smaps

```bash
# Get detailed memory breakdown
docker exec op-reth-seq sh -c '
  RETH_PID=$(pgrep -f "op-reth node" | head -1)
  cat /proc/$RETH_PID/smaps_rollup
'
```

Shows:
- RSS (Resident Set Size)
- PSS (Proportional Set Size)
- Shared/Private memory
- Anonymous/File-backed memory

### Using pmap

```bash
# Memory map overview
docker exec op-reth-seq sh -c '
  RETH_PID=$(pgrep -f "op-reth node" | head -1)
  pmap -x $RETH_PID
'
```

### Continuous Monitoring

```bash
# Monitor memory usage every 5 seconds
docker exec op-reth-seq sh -c '
  RETH_PID=$(pgrep -f "op-reth node" | head -1)
  while true; do
    echo "=== $(date) ==="
    ps -p $RETH_PID -o rss,vsz,pmem,cmd
    sleep 5
  done
' | tee memory-monitor.log
```

## Comparing Methods

| Method | Overhead | Detail | Use Case | Output |
|--------|----------|--------|----------|--------|
| **Jemalloc** | Very Low (<5%) | High | Development & Production | Heap dumps, flamegraphs |
| **/proc/smaps** | None | Low | Quick checks | Text summary |

**Recommendations:**
- **Development & Production**: Jemalloc (low overhead, detailed flamegraphs)
- **Quick checks**: /proc/smaps or pmap

## Common Memory Issues

### 1. Memory Leaks

**Symptoms:**
- RSS continuously grows
- Never plateaus even at idle
- No corresponding increase in workload

**Detection:**
```bash
# Collect multiple heap dumps over time
./scripts/profile-reth-jemalloc.sh op-reth-seq 300

# Generate flamegraph and look for:
# - Allocations with no corresponding frees
# - Growing allocation counts over time
./scripts/generate-memory-flamegraph.sh op-reth-seq all
```

### 2. Excessive Allocations

**Symptoms:**
- High allocation rate
- Good memory reclamation but poor performance
- CPU time spent in allocator

**Detection:**
```bash
# Use jemalloc to find allocation hotspots
./scripts/profile-reth-jemalloc.sh op-reth-seq 60
./scripts/generate-memory-flamegraph.sh op-reth-seq latest

# Look for:
# - Wide bars in flamegraph (functions allocating most memory)
```

### 3. Memory Bloat

**Symptoms:**
- More memory used than expected
- Working set larger than necessary

**Detection:**
```bash
# Use jemalloc to see live allocations
./scripts/profile-reth-jemalloc.sh op-reth-seq 60

# Look for:
# - Large allocations in unexpected places
# - Caches or buffers holding too much data
```

### 4. Fragmentation

**Symptoms:**
- RSS higher than sum of allocations
- Memory not released to OS
- Increasing RSS despite stable allocations

**Detection:**
```bash
# Check jemalloc stats
docker exec op-reth-seq sh -c '
  echo "stats_print" | nc localhost [jemalloc_stats_port]
'
```

## Troubleshooting

### "Jemalloc profiling is not enabled"

Jemalloc profiling must be enabled at process startup:

```bash
# Add to docker-compose.yml environment:
environment:
  - JEMALLOC_PROFILING=true

# Then restart the container
docker-compose restart op-reth-seq
```

### "Cannot attach to process"

```bash
# Ensure container has ptrace capabilities
docker inspect op-reth-seq | grep -i ptrace

# Should show: "SYS_PTRACE"
```

### High Overhead from Profiling

```bash
# Increase jemalloc sampling interval for lower overhead
# In docker-compose.yml:
environment:
  - _RJEM_MALLOC_CONF=prof:true,prof_prefix:/profiling/jeprof,lg_prof_sample:21

# lg_prof_sample:21 samples every 2MB instead of default 512KB
```

### No Symbols in Output

```bash
# Verify debug symbols present
docker exec op-reth-seq file /usr/local/bin/op-reth

# Should show: "with debug_info, not stripped"
```

### Mangled Rust Symbols in Flamegraph

```bash
# Install rustfilt for better demangling
cargo install rustfilt

# The generate-memory-flamegraph.sh script will automatically use it
```

## Best Practices

### 1. Profile Realistic Workloads

```bash
# Generate load while profiling
# Terminal 1: Generate transactions
cast send --rpc-url http://localhost:8123 ...

# Terminal 2: Profile
./scripts/profile-reth-jemalloc.sh op-reth-seq 60
./scripts/generate-memory-flamegraph.sh op-reth-seq latest
```

### 2. Multiple Profiling Sessions

```bash
# Capture different phases
./scripts/profile-reth-jemalloc.sh op-reth-seq 60  # Startup
# ... wait for steady state ...
./scripts/profile-reth-jemalloc.sh op-reth-seq 60  # Steady state
# ... trigger high load ...
./scripts/profile-reth-jemalloc.sh op-reth-seq 60  # Under load

# Generate flamegraphs for comparison
./scripts/generate-memory-flamegraph.sh op-reth-seq all
```

### 3. Combine CPU and Memory Profiling

```bash
# Run both simultaneously
./scripts/profile-reth-perf.sh op-reth-seq 60 &
./scripts/profile-reth-jemalloc.sh op-reth-seq 60 &
wait

# Analyze both:
# - CPU flamegraph shows compute hotspots
# - Memory flamegraph shows allocation hotspots
./scripts/generate-memory-flamegraph.sh op-reth-seq latest
```

### 4. Baseline Measurements

```bash
# Establish baseline before changes
./scripts/profile-reth-jemalloc.sh op-reth-seq 60
./scripts/generate-memory-flamegraph.sh op-reth-seq latest

# Make optimizations
# ...

# Compare after changes
./scripts/profile-reth-jemalloc.sh op-reth-seq 60
./scripts/generate-memory-flamegraph.sh op-reth-seq latest

# Look for:
# - Reduced peak memory
# - Fewer allocations
# - Lower allocation rates
```

### 5. Continuous Monitoring

For production systems:

```bash
# Enable jemalloc profiling with minimal overhead (in docker-compose.yml)
environment:
  - _RJEM_MALLOC_CONF=prof:true,prof_prefix:/profiling/jeprof,lg_prof_interval:33,lg_prof_sample:21

# This dumps heap every ~8GB allocated, sampling every 2MB
# Very low overhead, suitable for production
```

Or simply use `JEMALLOC_PROFILING=true` for default settings.

## Integration with Existing Profiling

### Combined CPU + Memory Analysis

```bash
# Run all profiling types
./scripts/profile-reth-perf.sh op-reth-seq 60 &       # CPU
./scripts/profile-reth-jemalloc.sh op-reth-seq 60 &  # Memory
wait

# Generate memory flamegraph
./scripts/generate-memory-flamegraph.sh op-reth-seq latest

# Analyze together to understand:
# - CPU hotspots (perf)
# - Memory bottlenecks (jemalloc)
```

### Decision Matrix

| Symptom | Profile Type | Tool |
|---------|--------------|------|
| High CPU usage | CPU | `profile-reth-perf.sh` |
| High memory | Memory | `profile-reth-jemalloc.sh` |
| Memory growing | Memory leak | `profile-reth-jemalloc.sh` (multiple dumps) |
| Slow allocations | CPU + Memory | Both perf and jemalloc |

## Resources

- [Jemalloc Profiling](https://github.com/jemalloc/jemalloc/wiki/Use-Case%3A-Heap-Profiling)
- [Linux Memory Management](https://www.kernel.org/doc/html/latest/admin-guide/mm/index.html)
- [Rust Performance Book](https://nnethercote.github.io/perf-book/)
