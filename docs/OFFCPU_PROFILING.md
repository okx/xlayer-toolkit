# Off-CPU Profiling Guide

This guide covers how to profile off-CPU time in op-reth to identify performance bottlenecks from lock contention, I/O waits, and scheduler delays.

## Table of Contents

- [Overview](#overview)
- [What is Off-CPU Profiling?](#what-is-off-cpu-profiling)
- [Quick Start](#quick-start)
- [Understanding the Output](#understanding-the-output)
- [Event Configuration](#event-configuration)
- [Analyzing Results](#analyzing-results)
- [Common Patterns](#common-patterns)
- [Troubleshooting](#troubleshooting)

## Overview

Off-CPU profiling helps you understand where reth spends time **not running on CPU**:
- **Lock contention**: Threads waiting to acquire locks
- **I/O waits**: Blocking on disk reads/writes/syncs
- **Scheduler delays**: Context switches and thread scheduling

Unlike CPU profiling (which shows what's using CPU cycles), off-CPU profiling shows what's **preventing** reth from using CPU cycles.

## What is Off-CPU Profiling?

### Why Off-CPU Time Matters

A program can be slow for two reasons:
1. **On-CPU**: Doing too much work (use CPU profiling)
2. **Off-CPU**: Blocked and not doing work (use off-CPU profiling)

Example: If reth takes 10 seconds to process a block:
- 1s on-CPU (actual computation)
- 9s off-CPU (waiting on locks, I/O, etc.) ← This is what we want to find!

### What We Capture

The off-CPU profiling script captures:
- **Futex syscalls**: When Rust `Mutex`, `RwLock`, or `parking_lot` locks block
- **Fsync operations**: When reth waits for data to be written to disk
- **Block I/O**: Disk read/write operations at the kernel level
- **Context switches**: When threads are switched off-CPU

**Important**: Each event includes a **full stack trace** showing which reth function caused the blocking operation.

## Quick Start

### Prerequisites

1. Build reth with profiling support:
   ```bash
   ./scripts/build-reth-with-profiling.sh
   ```

2. Update `docker-compose.yml` to use the profiling image:
   ```yaml
   op-reth-seq:
     image: ${OP_RETH_IMAGE_TAG:-op-reth:profiling}
   ```

3. Restart the container:
   ```bash
   docker-compose restart op-reth-seq
   ```

### Basic Usage

```bash
# Profile for 60 seconds (default)
./scripts/profile-reth-offcpu.sh

# Profile for 120 seconds
./scripts/profile-reth-offcpu.sh op-reth-seq 120

# Profile with custom event configuration
./scripts/profile-reth-offcpu.sh op-reth-seq 60 ./scripts/my-events.conf
```

### What You Get

After profiling completes, you'll find in `./profiling/op-reth-seq/`:
- `perf-offcpu-{timestamp}.data` - Raw perf data
- `perf-offcpu-{timestamp}.script` - Symbolicated stack traces
- `perf-offcpu-{timestamp}.svg` - Interactive flamegraph

## Understanding the Output

### Summary Statistics

The script outputs a summary of captured events:

```
=== Off-CPU Event Summary ===

Lock Contention (futex syscalls):
  futex calls:      1044
  futex returns:    1044
  futex_wait calls: 0
  futex_wait ret:   0
  → Lock contention detected! Check stack traces for Mutex/RwLock calls

I/O Operations:
  read syscalls:     132
  write syscalls:    454
  fsync calls:       36
  fdatasync calls:   0

Scheduler context switches:
1106

Block I/O operations:
  requests issued:    24
  requests completed: 24
```

**What this means**:
- **1044 futex calls**: Threads blocked on locks 1044 times
- **36 fsync calls**: Reth waited for disk sync 36 times
- **1106 context switches**: Threads were switched off-CPU 1106 times

### Stack Trace Example

When you search for futex events, you'll see stack traces like:

```
tokio-runtime-w    18 [001]  1735.043726:      syscalls:sys_enter_futex:
           e7be8 syscall+0x28 (libc)
         3043be7 crossbeam_channel::waker::SyncWaker::notify+0x12f
         3048a38 crossbeam_channel::channel::Sender<T>::try_send+0xc8
         3047fbc <tracing_appender::non_blocking::NonBlocking>::write+0xac
         2c242a8 <tracing_subscriber::filter::Filtered<L,F,S>>::on_event+0x74
         234674c <reth_node_events::node::EventHandler<E>>::poll+0x2d4
         1f243b8 <core::pin::Pin<P>>::poll+0x174
         1b29308 reth_tasks::TaskExecutor::spawn_critical_as+0x80
```

**Reading the stack trace** (bottom to top):
1. `reth_tasks::TaskExecutor::spawn_critical_as` - Reth code that started the operation
2. `reth_node_events::node::EventHandler::poll` - Which reth component
3. `tracing_subscriber` - Using the logging system
4. `crossbeam_channel::Sender::try_send` - Sending to a channel
5. `SyncWaker::notify` - Waking a waiting thread (requires lock)
6. `syscall` - The actual futex syscall

**This tells you**: The EventHandler in reth is experiencing lock contention when sending log messages through a crossbeam channel.

## Event Configuration

### Default Configuration

The default config (`scripts/offcpu-events.conf`) captures:
- Lock contention (futex events)
- Disk sync operations (fsync/fdatasync)
- Block I/O (block layer events)
- Context switches (sched_switch)

### Customizing Events

Create a custom config file:

```bash
# my-custom-events.conf
# Only capture lock contention and fsync
syscalls:sys_enter_futex
syscalls:sys_exit_futex
syscalls:sys_enter_fsync
sched:sched_switch
```

Use it:
```bash
./scripts/profile-reth-offcpu.sh op-reth-seq 60 ./my-custom-events.conf
```

### Available Events

**Lock Contention**:
- `syscalls:sys_enter_futex` - Lock wait begins
- `syscalls:sys_exit_futex` - Lock acquired
- `syscalls:sys_enter_futex_wait` - Futex wait (kernel 6+)
- `syscalls:sys_exit_futex_wait` - Futex wait returns

**Disk I/O**:
- `syscalls:sys_enter_fsync` - Blocking fsync
- `syscalls:sys_enter_fdatasync` - Blocking fdatasync
- `block:block_rq_issue` - Disk I/O request issued
- `block:block_rq_complete` - Disk I/O completed

**Scheduler**:
- `sched:sched_switch` - Context switch (thread goes off-CPU)

**⚠️ Warning**: Avoid high-frequency events like `sys_enter_read` or `sys_enter_write` as they generate millions of samples per second!

## Analyzing Results

### 1. View the Flamegraph

Open the generated SVG file in your browser:

```bash
open ./profiling/op-reth-seq/perf-offcpu-{timestamp}.svg
```

**What to look for**:
- **Wide bars** = Functions spending lots of time off-CPU
- **Lock symbols** = `futex`, `Mutex::lock`, `RwLock::write`, `parking_lot`
- **I/O symbols** = `fsync`, `write`, `block_rq`

Click on bars to zoom in and see the full call chain.

### 2. Search for Lock Contention

```bash
# Find all futex events with stack traces
grep -A 10 'syscalls:sys_enter_futex' ./profiling/op-reth-seq/perf-offcpu-{timestamp}.script
```

Look for patterns:
- Which reth components have the most futex calls?
- Which locks are contended? (`std::sync::Mutex`, `parking_lot::RwLock`)
- What operations trigger lock waits?

### 3. Interactive perf report

```bash
docker exec -it op-reth-seq /usr/bin/perf report -i /profiling/perf-offcpu.data
```

Navigate with arrow keys, press Enter to expand call chains.

### 4. Filter by Event Type

```bash
# Show only futex events
docker exec -it op-reth-seq /usr/bin/perf report -i /profiling/perf-offcpu.data --stdio | grep futex

# Show only fsync events
docker exec -it op-reth-seq /usr/bin/perf report -i /profiling/perf-offcpu.data --stdio | grep fsync
```

## Common Patterns

### Lock Contention Patterns

**Pattern 1: Channel Send/Recv**
```
crossbeam_channel::Sender::send
  → futex syscall
```
**What it means**: Threads are blocking when sending to a full channel or receiving from an empty channel.

**Fix**: Increase channel capacity or use try_send/try_recv.

**Pattern 2: RwLock Write Contention**
```
parking_lot::RwLock::write
  → futex syscall
```
**What it means**: Multiple threads trying to acquire write lock simultaneously.

**Fix**:
- Use read locks where possible
- Reduce lock hold time
- Consider lock-free data structures

**Pattern 3: Database Lock**
```
reth_db::Database::put
  parking_lot::Mutex::lock
    → futex syscall
```
**What it means**: Database operations are serialized by a lock.

**Fix**: Batch operations, use concurrent transactions if available.

### I/O Wait Patterns

**Pattern 1: Fsync on Every Write**
```
reth_db::Database::commit
  fsync
```
**What it means**: Every commit waits for disk sync.

**Fix**: Batch commits, use write-ahead logging, adjust sync strategy.

**Pattern 2: Block I/O Backlog**
```
High block_rq_issue count
Low block_rq_complete rate
```
**What it means**: Disk I/O is slow or saturated.

**Fix**: Use faster storage (NVMe), check disk health, reduce write amplification.

## Troubleshooting

### Too Many Samples

**Problem**: Step [5/5] takes forever, multi-GB perf.data file.

**Solution**: Remove high-frequency events from config file:
```bash
# Don't include these:
# syscalls:sys_enter_read
# syscalls:sys_enter_write
```

### No Events Captured

**Problem**: Summary shows all zeros.

**Cause**: Events not available in kernel or profiling too short.

**Solution**:
1. Check available events: `docker exec op-reth-seq perf list | grep -E "sched:|syscalls:"`
2. Profile for longer duration: `./scripts/profile-reth-offcpu.sh op-reth-seq 300`

### Permission Denied

**Problem**: `perf_event_paranoid` errors.

**Cause**: Docker doesn't have permission to use perf events.

**Solution**: Run with `--privileged` or set `--cap-add=SYS_ADMIN`.

### Stack Traces Show Addresses Only

**Problem**: Flamegraph shows hex addresses instead of function names.

**Cause**: Missing debug symbols.

**Solution**: Rebuild with `build-reth-with-profiling.sh` which enables debug symbols.

## Best Practices

1. **Start with default config**: Use `offcpu-events.conf` for general profiling
2. **Profile under load**: Run profiling when reth is actively syncing/processing
3. **Multiple samples**: Take profiles at different times to find consistent patterns
4. **Compare with CPU profile**: Off-CPU + CPU profiling gives complete picture
5. **Focus on wide bars**: In flamegraphs, wide bars = high impact
6. **Check timestamps**: Each profile is a snapshot - compare different periods

## Example Workflow

```bash
# 1. Build profiling image
./scripts/build-reth-with-profiling.sh

# 2. Start reth with profiling support
docker-compose restart op-reth-seq

# 3. Wait for reth to start syncing
sleep 60

# 4. Profile for 2 minutes during sync
./scripts/profile-reth-offcpu.sh op-reth-seq 120

# 5. Open flamegraph
open ./profiling/op-reth-seq/perf-offcpu-*.svg

# 6. Search for lock contention
grep -A 15 'syscalls:sys_enter_futex' ./profiling/op-reth-seq/perf-offcpu-*.script | less

# 7. Identify hotspots and optimize
# (e.g., reduce lock hold time, batch operations, etc.)
```

## Related Documentation

- [CPU Profiling Guide](./PROFILING_RETH.md) - For on-CPU performance analysis
- [Memory Profiling Guide](./MEMORY_PROFILING.md) - For memory usage analysis
- [Perf TUI Reference](./PERF_TUI_REFERENCE.md) - Interactive perf commands

## Additional Resources

- [Brendan Gregg's Off-CPU Analysis](http://www.brendangregg.com/offcpuanalysis.html)
- [Linux perf Examples](http://www.brendangregg.com/perf.html)
- [Flamegraph Documentation](https://github.com/brendangregg/FlameGraph)
