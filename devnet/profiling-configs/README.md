# Off-CPU Profiling Configurations

This directory contains event configuration files for off-CPU profiling with perf.

## Available Configurations

### `offcpu-events.conf` (Default)
**General-purpose off-CPU profiling** - captures lock contention, disk sync, and block I/O.

```bash
./scripts/profile-reth-offcpu.sh op-reth-seq 60
```

**Events captured:**
- Lock contention (futex syscalls)
- Disk sync operations (fsync/fdatasync)
- Block I/O (block layer events)

**Use when:** You want a general overview of where reth is blocked.

---

### `offcpu-events-contextswitches.conf`
**Context switch profiling** - identifies which reth functions cause the most context switches.

```bash
./scripts/profile-reth-offcpu.sh op-reth-seq 60 ./profiling-configs/offcpu-events-contextswitches.conf
```

**Events captured:**
- `sched:sched_switch` - every context switch event

**Use when:** You want to identify which functions are going off-CPU most frequently.

**Note:** Generates high sample counts (~100k-150k events/min). **Fast mode auto-enabled** - skips symbolication and generates quick summary instead (~10x faster).

---

### `offcpu-events-iobandwidth.conf`
**I/O bandwidth analysis** - measures how much data each reth function reads/writes.

```bash
# Profile
./scripts/profile-reth-offcpu.sh op-reth-seq 60 ./profiling-configs/offcpu-events-iobandwidth.conf

# Analyze
./scripts/analyze-io-bandwidth.sh ./profiling/op-reth-seq/perf-offcpu-{timestamp}.script
```

**Events captured:**
- `sys_enter_read/write` - captures syscall read/write with byte counts
- `sys_enter_pread64/pwrite64` - positional I/O operations
- Block layer events

**Use when:** You need to measure actual I/O bandwidth per function.

**Note:** Generates very high sample counts (50k-500k+ events/min). **Fast mode auto-enabled**. Use shorter durations (30-60s). For detailed bandwidth analysis, generate full script with `SKIP_SCRIPT=false`.

---

### `offcpu-events-pagefaults.conf`
**Page fault profiling** - reveals memory-mapped I/O (mmap) disk reads.

```bash
./scripts/profile-reth-offcpu.sh op-reth-seq 60 ./profiling-configs/offcpu-events-pagefaults.conf
```

**Events captured:**
- `major-faults` - page faults requiring disk reads (mmap'd pages not in RAM)
- `minor-faults` - page faults resolved from RAM cache
- `vmscan:*` - memory pressure events

**Use when:** You want to understand:
- How much data is read from disk via mmap (MDBX database)
- Cache hit rate for memory-mapped files
- Whether reth has memory pressure

**Why this matters:** `sys_enter_read` only shows ~5KB of reads (metadata), but major faults reveal the actual bulk data reads from MDBX's memory-mapped database files.

---

## Creating Custom Configurations

To create a custom config:

1. Copy an existing config file:
   ```bash
   cp ./profiling-configs/offcpu-events.conf ./profiling-configs/my-custom.conf
   ```

2. Edit the file to include only the events you need:
   ```bash
   # my-custom.conf
   syscalls:sys_enter_futex
   syscalls:sys_exit_futex
   major-faults
   minor-faults
   ```

3. Use it with the profiling script:
   ```bash
   ./scripts/profile-reth-offcpu.sh op-reth-seq 60 ./profiling-configs/my-custom.conf
   ```

## Available Event Types

**Lock Contention:**
- `syscalls:sys_enter_futex`, `syscalls:sys_exit_futex`
- `syscalls:sys_enter_futex_wait`, `syscalls:sys_exit_futex_wait`

**Disk I/O:**
- `syscalls:sys_enter_fsync`, `syscalls:sys_enter_fdatasync`
- `block:block_rq_issue`, `block:block_rq_complete`
- `syscalls:sys_enter_read`, `syscalls:sys_enter_write`
- `syscalls:sys_enter_pread64`, `syscalls:sys_enter_pwrite64`

**Scheduler:**
- `sched:sched_switch` ⚠️ High frequency!

**Page Faults:**
- `major-faults`, `minor-faults`, `page-faults`

**Memory Pressure:**
- `vmscan:mm_vmscan_direct_reclaim_begin/end`
- `vmscan:mm_vmscan_kswapd_wake`

## See Also

- [Off-CPU Profiling Guide](../../docs/OFFCPU_PROFILING.md) - Complete documentation
- [Profile Reth Script](../scripts/profile-reth-offcpu.sh) - Main profiling script
- [Analyze I/O Bandwidth Script](../scripts/analyze-io-bandwidth.sh) - I/O analysis tool
