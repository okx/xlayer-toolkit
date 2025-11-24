# Off-CPU Profiling Guide

Off-CPU profiling shows where your program is **blocked or waiting**, rather than actively using CPU. This is critical for identifying performance bottlenecks in I/O-bound workloads, lock contention, and async operations.

## What Off-CPU Profiling Shows

- **Disk I/O waits**: Reading/writing to disk
- **Network I/O waits**: Waiting for network responses
- **Lock contention**: Waiting for mutexes, locks, semaphores
- **Sleep/timers**: Explicit sleeps or timer waits
- **Scheduler waits**: Waiting to be scheduled by the OS
- **Page faults**: Waiting for memory pages to be loaded

## Off-CPU vs CPU Profiling

| Metric | CPU Profiling | Off-CPU Profiling |
|--------|---------------|-------------------|
| **Shows** | Active computation | Blocking/waiting time |
| **Use for** | Algorithm optimization | I/O, locks, concurrency |
| **Example** | Hot loops, calculations | Database queries, file reads |
| **Tool** | `perf record -F 999` | `perf record -e sched:sched_switch` |

## Method 1: Perf with Scheduler Events (Recommended)

Uses perf to track when threads are descheduled (blocked).

### Basic Off-CPU Profiling

```bash
./scripts/profile-reth-offcpu.sh op-reth-seq 60
```

This script captures scheduler events to track blocking time.

### Manual Off-CPU Profiling

```bash
# In the container
docker exec op-reth-seq sh -c '
  # Find reth PID
  RETH_PID=$(pgrep -f "op-reth node" | head -1)

  # Record scheduler events for 60 seconds
  perf_5.10 record \
    -e sched:sched_switch \
    -e sched:sched_stat_sleep \
    -e sched:sched_stat_blocked \
    -g -p $RETH_PID \
    -o /profiling/offcpu.data \
    -- sleep 60
'

# Copy and generate report
docker cp op-reth-seq:/profiling/offcpu.data ./profiling/op-reth-seq/
docker exec op-reth-seq perf_5.10 script -i /profiling/offcpu.data > ./profiling/op-reth-seq/offcpu.script
```

### Generate Off-CPU Flamegraph

```bash
# The flamegraph shows blocking time instead of CPU time
./scripts/generate-flamegraph.sh op-reth-seq offcpu.script
```

## Method 2: BPF/eBPF Tools (Advanced)

More accurate but requires BPF support and additional tools.

### Install BCC Tools in Container

First, update the Dockerfile to include BCC tools:

```dockerfile
# In Dockerfile.profiling
RUN apt-get update && apt-get install -y \
    linux-perf \
    bpfcc-tools \
    && rm -rf /var/lib/apt/lists/*
```

### Using `offcputime` from BCC

```bash
# Record off-CPU time for 60 seconds
docker exec op-reth-seq sh -c '
  RETH_PID=$(pgrep -f "op-reth node" | head -1)

  # Capture off-CPU stacks (requires kernel >= 4.6)
  /usr/share/bcc/tools/offcputime \
    -d -f -p $RETH_PID 60 \
    > /profiling/offcpu.folded
'

# Generate flamegraph
docker cp op-reth-seq:/profiling/offcpu.folded ./profiling/op-reth-seq/
cd ./profiling/FlameGraph
./flamegraph.pl \
  --title="Off-CPU Time" \
  --colors=io \
  ../op-reth-seq/offcpu.folded \
  > ../op-reth-seq/offcpu-bpf.svg
```

### Using `bpftrace` (Most Flexible)

```bash
# Install bpftrace
docker exec op-reth-seq apt-get update && apt-get install -y bpftrace

# Custom off-CPU profiling script
docker exec op-reth-seq sh -c '
cat > /tmp/offcpu.bt <<EOF
#!/usr/bin/env bpftrace

kprobe:schedule
{
  @start[tid] = nsecs;
}

kretprobe:schedule
/@start[tid]/
{
  \$duration = nsecs - @start[tid];
  if (\$duration > 1000000) {  // Only track waits > 1ms
    @offcpu_us[ustack, kstack] = sum(\$duration / 1000);
  }
  delete(@start[tid]);
}

END
{
  clear(@start);
}
EOF

  RETH_PID=$(pgrep -f "op-reth node" | head -1)
  bpftrace /tmp/offcpu.bt -p $RETH_PID --unsafe -f json > /profiling/offcpu-bpf.json
'
```

## Method 3: Combined On/Off CPU Profiling

Get the complete picture by profiling both CPU and off-CPU time.

### Simultaneous Collection

```bash
# Terminal 1: CPU profiling
./scripts/profile-reth-perf.sh op-reth-seq 60 &
CPU_PID=$!

# Terminal 2: Off-CPU profiling
./scripts/profile-reth-offcpu.sh op-reth-seq 60 &
OFFCPU_PID=$!

# Wait for both to complete
wait $CPU_PID
wait $OFFCPU_PID

# Generate both flamegraphs
./scripts/generate-flamegraph.sh op-reth-seq perf-*.script
./scripts/generate-flamegraph.sh op-reth-seq offcpu-*.script
```

### Compare Results

```bash
# Open both in browser
open ./profiling/op-reth-seq/perf-*.svg        # On-CPU
open ./profiling/op-reth-seq/offcpu-*.svg      # Off-CPU
```

## Automated Off-CPU Profiling Script

Create `scripts/profile-reth-offcpu.sh`:

```bash
#!/bin/bash

set -e

CONTAINER=${1:-op-reth-seq}
DURATION=${2:-60}
OUTPUT_DIR="./profiling/${CONTAINER}"

echo "=== Reth Off-CPU Profiling ==="
echo "Container: $CONTAINER"
echo "Duration: ${DURATION}s"
echo ""

mkdir -p "$OUTPUT_DIR"

# Configure kernel
docker exec "$CONTAINER" sh -c '
    echo -1 > /proc/sys/kernel/perf_event_paranoid 2>/dev/null || true
    echo 0 > /proc/sys/kernel/kptr_restrict 2>/dev/null || true
'

# Find reth PID
echo "[1/4] Finding op-reth process..."
RETH_PID=$(docker exec "$CONTAINER" sh -c 'pgrep -f "op-reth node" | head -1')

if [ -z "$RETH_PID" ]; then
    echo "Error: Could not find op-reth process"
    exit 1
fi

echo "Found PID: $RETH_PID"

# Find perf binary
PERF_BIN=$(docker exec "$CONTAINER" sh -c 'which perf_5.10 2>/dev/null || echo perf')

# Record off-CPU events
echo "[2/4] Recording off-CPU events for ${DURATION}s..."
docker exec "$CONTAINER" sh -c "
    cd /profiling && \
    $PERF_BIN record \
      -e sched:sched_switch \
      -e sched:sched_stat_sleep \
      -e sched:sched_stat_blocked \
      -g --call-graph fp \
      -p $RETH_PID \
      -o offcpu.data \
      -- sleep ${DURATION}
"

# Generate script output
echo "[3/4] Generating symbolicated output..."
docker exec "$CONTAINER" sh -c "
    cd /profiling && \
    $PERF_BIN script -i offcpu.data > offcpu.script
"

# Copy results
echo "[4/4] Copying results..."
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
docker cp "$CONTAINER:/profiling/offcpu.data" "$OUTPUT_DIR/offcpu-${TIMESTAMP}.data"
docker cp "$CONTAINER:/profiling/offcpu.script" "$OUTPUT_DIR/offcpu-${TIMESTAMP}.script"

# Clean up
docker exec "$CONTAINER" sh -c 'rm -f /profiling/offcpu.{data,script}' 2>/dev/null || true

echo ""
echo "Off-CPU profile collected successfully!"
echo "  - offcpu.data: $OUTPUT_DIR/offcpu-${TIMESTAMP}.data"
echo "  - offcpu.script: $OUTPUT_DIR/offcpu-${TIMESTAMP}.script"
echo ""

# Generate flamegraph
if [ -x "./scripts/generate-flamegraph.sh" ]; then
    echo "[5/5] Generating off-CPU flamegraph..."
    ./scripts/generate-flamegraph.sh "$CONTAINER" "offcpu-${TIMESTAMP}.script" "Off-CPU Time"
fi
```

## Interpreting Off-CPU Flamegraphs

### What to Look For

1. **Wide stacks in I/O functions**: Disk/network bottlenecks
   - `read()`, `write()`, `recv()`, `send()`
   - Database queries
   - File operations

2. **Lock contention**:
   - `pthread_mutex_lock`
   - `std::sync::Mutex::lock`
   - `parking_lot::*`

3. **Async waits**:
   - `tokio::*::wait`
   - `futures::*::poll`
   - Event loop blocking

4. **Sleep/timers**:
   - `sleep()`, `nanosleep()`
   - Timer waits

### Example Analysis

```bash
# Generate off-CPU flamegraph
./scripts/profile-reth-offcpu.sh op-reth-seq 60

# Open in browser
open ./profiling/op-reth-seq/offcpu-*.svg
```

**If you see**:
- **Wide stacks in `tokio::task::blocking`** → Thread pool exhaustion
- **Wide stacks in `std::sync::Mutex`** → Lock contention
- **Wide stacks in `read`/`write`** → I/O bottleneck
- **Wide stacks in `futex`** → Synchronization overhead

## Combining CPU + Off-CPU Analysis

### Complete Performance Picture

```bash
# 1. Run both profiles
./scripts/profile-reth-perf.sh op-reth-seq 60 &      # CPU
./scripts/profile-reth-offcpu.sh op-reth-seq 60 &   # Off-CPU
wait

# 2. Compare results
TIMESTAMP=$(ls -t ./profiling/op-reth-seq/perf-*.svg | head -1 | grep -o '[0-9]\{8\}-[0-9]\{6\}')

echo "CPU Flamegraph:     ./profiling/op-reth-seq/perf-${TIMESTAMP}.svg"
echo "Off-CPU Flamegraph: ./profiling/op-reth-seq/offcpu-${TIMESTAMP}.svg"
```

### Decision Matrix

| Observation | Likely Issue | Next Step |
|-------------|--------------|-----------|
| High CPU, low off-CPU | CPU-bound | Optimize algorithms |
| Low CPU, high off-CPU | I/O-bound | Optimize I/O, add caching |
| Both high | Mixed workload | Profile both types |
| Both low | Idle or waiting | Generate more load |

## Advanced: Differential Off-CPU Profiling

Track only specific types of blocking:

### I/O Only

```bash
docker exec op-reth-seq perf_5.10 record \
  -e syscalls:sys_enter_read \
  -e syscalls:sys_enter_write \
  -g -p $RETH_PID -- sleep 60
```

### Lock Contention Only

```bash
docker exec op-reth-seq perf_5.10 record \
  -e syscalls:sys_enter_futex \
  -g -p $RETH_PID -- sleep 60
```

### Network I/O Only

```bash
docker exec op-reth-seq perf_5.10 record \
  -e syscalls:sys_enter_recvfrom \
  -e syscalls:sys_enter_sendto \
  -g -p $RETH_PID -- sleep 60
```

## Troubleshooting

### "event not supported" errors

Some events require specific kernel versions:
```bash
# Check available events
docker exec op-reth-seq perf_5.10 list | grep sched
```

### Large data files

Off-CPU profiling can generate large files:
```bash
# Filter to only significant waits (>10ms)
docker exec op-reth-seq perf_5.10 record \
  --switch-max-files=10 \
  -e sched:sched_switch \
  -g -p $RETH_PID -- sleep 60
```

### Missing stacks

Ensure frame pointers are enabled (already done in profiling build):
```bash
RUSTFLAGS="-C force-frame-pointers=yes"
```

## Best Practices

1. **Profile both CPU and off-CPU**: Get the complete picture
2. **Profile under realistic load**: Idle systems show different patterns
3. **Look for patterns**: Consistent wide stacks indicate bottlenecks
4. **Compare before/after**: Validate optimization impact
5. **Filter noise**: Focus on waits >1ms for most applications

## Resources

- [Off-CPU Analysis](https://www.brendangregg.com/offcpuanalysis.html)
- [BCC Tools](https://github.com/iovisor/bcc)
- [bpftrace Guide](https://github.com/iovisor/bpftrace)
- [Linux Perf Examples](https://www.brendangregg.com/perf.html)
