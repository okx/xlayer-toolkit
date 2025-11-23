# Memory Profiling Guide for Reth

This guide explains how to profile memory usage in op-reth using various tools including heaptrack, jemalloc profiling, and valgrind massif.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Method 1: Heaptrack (Recommended)](#method-1-heaptrack-recommended)
  - [Basic Usage](#basic-usage)
  - [Analyzing Results](#analyzing-results)
- [Method 2: Jemalloc Heap Profiling](#method-2-jemalloc-heap-profiling)
  - [Enable Profiling](#enable-profiling)
  - [Collecting Heap Dumps](#collecting-heap-dumps)
  - [Generating Flamegraphs](#generating-flamegraphs)
- [Method 3: Valgrind Massif](#method-3-valgrind-massif)
  - [Running Massif](#running-massif)
  - [Visualizing Memory Over Time](#visualizing-memory-over-time)
- [Method 4: Live Memory Analysis](#method-4-live-memory-analysis)
- [Comparing Methods](#comparing-methods)
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
# Option 1: Heaptrack (easiest, most comprehensive)
./scripts/profile-reth-heaptrack.sh op-reth-seq 60

# Option 2: Jemalloc (production-ready, low overhead)
./scripts/profile-reth-jemalloc.sh op-reth-seq 60

# Option 3: Valgrind Massif (memory over time)
./scripts/profile-reth-massif.sh op-reth-seq 60
```

## Method 1: Heaptrack (Recommended)

Heaptrack provides the most user-friendly memory profiling experience with excellent visualization.

### What Heaptrack Shows

- **Allocation hotspots**: Functions allocating the most memory
- **Temporary allocations**: Short-lived objects
- **Leak candidates**: Memory never freed
- **Peak memory**: Maximum memory usage over time
- **Allocation flamegraphs**: Visual call stacks

### Basic Usage

```bash
# Profile for 60 seconds
./scripts/profile-reth-heaptrack.sh op-reth-seq 60

# Profile for 2 minutes
./scripts/profile-reth-heaptrack.sh op-reth-seq 120
```

**Output:**
- `./profiling/op-reth-seq/heaptrack-TIMESTAMP.data.gz` - Raw heaptrack data
- `./profiling/op-reth-seq/heaptrack-TIMESTAMP.txt` - Text summary
- `./profiling/op-reth-seq/heaptrack-TIMESTAMP-allocations.svg` - Allocation flamegraph

### Analyzing Results

#### View Text Summary

```bash
cat ./profiling/op-reth-seq/heaptrack-*.txt
```

This shows:
- Peak memory usage
- Total allocations
- Temporary allocations
- Top allocation sites

#### View Flamegraph

```bash
open ./profiling/op-reth-seq/heaptrack-*-allocations.svg
```

**Reading the flamegraph:**
- **Width** = Total bytes allocated (wider = more memory)
- **Color** = Different code paths
- **Click** to zoom into specific call paths
- **Search** to find specific functions

#### GUI Analysis (Advanced)

If you have heaptrack_gui installed locally:

```bash
# Copy data file to your local machine
docker cp op-reth-seq:/profiling/heaptrack.data.gz ./heaptrack.data.gz

# Open in GUI (if available)
heaptrack_gui heaptrack.data.gz
```

### Manual Heaptrack Profiling

For more control:

```bash
docker exec op-reth-seq sh -c '
  RETH_PID=$(pgrep -f "op-reth node" | head -1)

  # Attach heaptrack to running process
  heaptrack -p $RETH_PID -o /profiling/heaptrack

  # Let it run for desired duration
  sleep 60

  # Stop with Ctrl+C or kill heaptrack process
'

# Generate reports
docker exec op-reth-seq sh -c '
  heaptrack_print /profiling/heaptrack.*.gz > /profiling/heaptrack-report.txt
'
```

## Method 2: Jemalloc Heap Profiling

Since reth is built with jemalloc, you can use its native profiling capabilities with minimal overhead.

### What Jemalloc Profiling Shows

- **Live allocations**: Current heap state
- **Allocation call stacks**: Where memory is allocated
- **Per-allocation-site statistics**: Bytes and counts
- **Heap dumps**: Snapshots at specific times

### Enable Profiling

Jemalloc profiling is controlled via environment variables:

```bash
# In docker-compose.yml or when starting reth
MALLOC_CONF="prof:true,prof_prefix:/profiling/jeprof,lg_prof_interval:30"
```

**Options:**
- `prof:true` - Enable profiling
- `prof_prefix:<path>` - Output file prefix
- `lg_prof_interval:N` - Dump heap every 2^N bytes allocated
- `lg_prof_sample:N` - Sample rate (default: 19 = every 512KB)

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
# Generate flamegraph from heap dump
./scripts/generate-memory-flamegraph.sh op-reth-seq jeprof.*.heap
```

### Manual Jemalloc Profiling

```bash
# Enable profiling for running container
docker exec op-reth-seq sh -c '
  export MALLOC_CONF="prof:true,prof_prefix:/profiling/jeprof,lg_prof_interval:30"

  # Trigger manual heap dump (if jemalloc supports PROF signal)
  RETH_PID=$(pgrep -f "op-reth node" | head -1)
  kill -USR1 $RETH_PID
'

# Convert heap dump to text
docker exec op-reth-seq sh -c '
  jeprof --text /usr/local/bin/op-reth /profiling/jeprof.*.heap > /profiling/jemalloc-report.txt
'

# Generate flamegraph
docker exec op-reth-seq sh -c '
  jeprof --collapsed /usr/local/bin/op-reth /profiling/jeprof.*.heap > /profiling/jemalloc.folded
'
```

### Analyzing Jemalloc Output

```bash
# View top allocation sites
docker exec op-reth-seq jeprof --text /usr/local/bin/op-reth /profiling/jeprof.*.heap | head -50

# Generate PDF report (if graphviz available)
docker exec op-reth-seq jeprof --pdf /usr/local/bin/op-reth /profiling/jeprof.*.heap > jemalloc.pdf
```

## Method 3: Valgrind Massif

Massif tracks memory usage over time, showing how memory consumption changes during execution.

### What Massif Shows

- **Memory timeline**: Usage over time
- **Peak memory**: When and where maximum memory was used
- **Heap growth**: How memory consumption increases
- **Stack vs heap**: Breakdown of memory usage

### Running Massif

```bash
# Profile for 60 seconds
./scripts/profile-reth-massif.sh op-reth-seq 60
```

**Output:**
- `./profiling/op-reth-seq/massif-TIMESTAMP.out` - Raw massif data
- `./profiling/op-reth-seq/massif-TIMESTAMP.txt` - Text report
- `./profiling/op-reth-seq/massif-TIMESTAMP.png` - Memory timeline graph

### Visualizing Memory Over Time

```bash
# View text report
cat ./profiling/op-reth-seq/massif-*.txt

# Generate graph with massif-visualizer (if available locally)
massif-visualizer ./profiling/op-reth-seq/massif-*.out
```

### Manual Massif Profiling

```bash
# Run reth under massif (WARNING: Very slow!)
docker exec op-reth-seq sh -c '
  # Stop current reth
  killall op-reth

  # Start under massif
  valgrind --tool=massif \
    --massif-out-file=/profiling/massif.out \
    --time-unit=ms \
    --detailed-freq=10 \
    /usr/local/bin/op-reth node \
    [... your reth args ...]
'

# Analyze results
docker exec op-reth-seq ms_print /profiling/massif.out > massif-report.txt
```

**Warning:** Massif has 10-20x overhead. Not suitable for production profiling.

## Method 4: Live Memory Analysis

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
| **Heaptrack** | Low (5-10%) | High | Development, debugging | Flamegraphs, GUI |
| **Jemalloc** | Very Low (<5%) | Medium | Production, continuous | Heap dumps, text |
| **Massif** | Very High (10-20x) | Medium | Memory timeline | Graphs, reports |
| **/proc/smaps** | None | Low | Quick checks | Text summary |

**Recommendations:**
- **Development**: Heaptrack (easiest, most comprehensive)
- **Production**: Jemalloc (low overhead, always-on capability)
- **Memory leaks**: Heaptrack or Massif
- **Quick checks**: /proc/smaps or pmap

## Common Memory Issues

### 1. Memory Leaks

**Symptoms:**
- RSS continuously grows
- Never plateaus even at idle
- No corresponding increase in workload

**Detection:**
```bash
# Run heaptrack for extended period
./scripts/profile-reth-heaptrack.sh op-reth-seq 300

# Look for:
# - Allocations with no corresponding frees
# - Growing allocation counts over time
```

### 2. Excessive Allocations

**Symptoms:**
- High allocation rate
- Good memory reclamation but poor performance
- CPU time spent in allocator

**Detection:**
```bash
# Use heaptrack to find allocation hotspots
./scripts/profile-reth-heaptrack.sh op-reth-seq 60

# Look for:
# - Wide bars in flamegraph
# - High "temporary allocations" count
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

### "heaptrack: command not found"

```bash
# Rebuild container with memory profiling tools
./scripts/build-reth-with-profiling.sh
```

### "Cannot attach to process"

```bash
# Ensure container has ptrace capabilities
docker inspect op-reth-seq | grep -i ptrace

# Should show: "SYS_PTRACE"
```

### High Overhead from Profiling

```bash
# For heaptrack, reduce sampling
docker exec op-reth-seq heaptrack -p $PID --sample-rate 100

# For jemalloc, increase sampling interval
MALLOC_CONF="prof:true,lg_prof_sample:21"  # Sample every 2MB instead of 512KB
```

### No Symbols in Output

```bash
# Verify debug symbols present
docker exec op-reth-seq file /usr/local/bin/op-reth

# Should show: "with debug_info, not stripped"
```

### Massif Too Slow

```bash
# Reduce detail frequency
valgrind --tool=massif --detailed-freq=100  # Instead of default 10

# Or use heaptrack/jemalloc instead
```

## Best Practices

### 1. Profile Realistic Workloads

```bash
# Generate load while profiling
# Terminal 1: Generate transactions
cast send --rpc-url http://localhost:8123 ...

# Terminal 2: Profile
./scripts/profile-reth-heaptrack.sh op-reth-seq 60
```

### 2. Multiple Profiling Sessions

```bash
# Capture different phases
./scripts/profile-reth-heaptrack.sh op-reth-seq 60  # Startup
# ... wait for steady state ...
./scripts/profile-reth-heaptrack.sh op-reth-seq 60  # Steady state
# ... trigger high load ...
./scripts/profile-reth-heaptrack.sh op-reth-seq 60  # Under load
```

### 3. Combine CPU and Memory Profiling

```bash
# Run both simultaneously
./scripts/profile-reth-perf.sh op-reth-seq 60 &
./scripts/profile-reth-heaptrack.sh op-reth-seq 60 &
wait

# Analyze both:
# - CPU flamegraph shows compute hotspots
# - Memory flamegraph shows allocation hotspots
```

### 4. Baseline Measurements

```bash
# Establish baseline before changes
./scripts/profile-reth-heaptrack.sh op-reth-seq 60

# Make optimizations
# ...

# Compare after changes
./scripts/profile-reth-heaptrack.sh op-reth-seq 60

# Look for:
# - Reduced peak memory
# - Fewer allocations
# - Lower allocation rates
```

### 5. Continuous Monitoring

For production systems:

```bash
# Enable jemalloc profiling with minimal overhead
MALLOC_CONF="prof:true,prof_prefix:/profiling/jeprof,lg_prof_interval:33,lg_prof_sample:21"

# This dumps heap every ~8GB allocated, sampling every 2MB
# Very low overhead, suitable for production
```

## Integration with Existing Profiling

### Combined CPU + Memory Analysis

```bash
# Run all profiling types
./scripts/profile-reth-perf.sh op-reth-seq 60 &       # On-CPU
./scripts/profile-reth-offcpu.sh op-reth-seq 60 &    # Off-CPU
./scripts/profile-reth-heaptrack.sh op-reth-seq 60 & # Memory
wait

# Analyze together to understand:
# - CPU hotspots (perf)
# - I/O bottlenecks (offcpu)
# - Memory bottlenecks (heaptrack)
```

### Decision Matrix

| Symptom | Profile Type | Tool |
|---------|--------------|------|
| High CPU usage | On-CPU | `profile-reth-perf.sh` |
| Slow responses | Off-CPU | `profile-reth-offcpu.sh` |
| High memory | Memory | `profile-reth-heaptrack.sh` |
| Memory growing | Memory leak | `profile-reth-massif.sh` |
| Slow allocations | CPU + Memory | Both perf and heaptrack |

## Resources

- [Heaptrack Documentation](https://github.com/KDE/heaptrack)
- [Jemalloc Profiling](https://github.com/jemalloc/jemalloc/wiki/Use-Case%3A-Heap-Profiling)
- [Valgrind Massif](https://valgrind.org/docs/manual/ms-manual.html)
- [Linux Memory Management](https://www.kernel.org/doc/html/latest/admin-guide/mm/index.html)
- [Rust Performance Book](https://nnethercote.github.io/perf-book/)
