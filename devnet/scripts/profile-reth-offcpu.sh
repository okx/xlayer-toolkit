#!/bin/bash

set -e

# Configuration
CONTAINER=${1:-op-reth-seq}
DURATION=${2:-60}
EVENT_CONFIG=${3:-"./profiling-configs/offcpu-events.conf"}
SKIP_SCRIPT=${SKIP_SCRIPT:-false}  # Set SKIP_SCRIPT=true to skip symbolication
OUTPUT_DIR="./profiling/${CONTAINER}"

echo "=== Reth Off-CPU Profiling with perf ==="
echo "Container: $CONTAINER"
echo "Duration: ${DURATION}s"
echo "Event Config: $EVENT_CONFIG"
if [ "$SKIP_SCRIPT" = "true" ]; then
    echo "Script generation: SKIPPED (use perf report directly)"
fi
echo "Output Directory: $OUTPUT_DIR"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Load events from config file
if [ ! -f "$EVENT_CONFIG" ]; then
    echo "Error: Event config file not found: $EVENT_CONFIG"
    exit 1
fi

echo "Loading events from: $EVENT_CONFIG"
# Read non-comment, non-empty lines from config file
EVENTS=$(grep -v '^#' "$EVENT_CONFIG" | grep -v '^[[:space:]]*$' | tr '\n' ' ' | sed 's/ $//')

if [ -z "$EVENTS" ]; then
    echo "Error: No events found in config file"
    exit 1
fi

EVENT_COUNT=$(echo "$EVENTS" | wc -w | tr -d ' ')
echo "Loaded $EVENT_COUNT events from config file"
echo ""

# Check if container is running
if ! docker ps | grep -q "$CONTAINER"; then
    echo "Error: Container $CONTAINER is not running"
    exit 1
fi

# Set perf_event_paranoid to allow profiling
echo "[1/5] Configuring kernel settings for profiling..."
docker exec "$CONTAINER" sh -c '
    if [ -w /proc/sys/kernel/perf_event_paranoid ]; then
        echo -1 > /proc/sys/kernel/perf_event_paranoid
        echo "Set perf_event_paranoid to -1 (allows all perf events)"
    else
        echo "Warning: Cannot write to /proc/sys/kernel/perf_event_paranoid"
    fi
    if [ -w /proc/sys/kernel/kptr_restrict ]; then
        echo 0 > /proc/sys/kernel/kptr_restrict
        echo "Set kptr_restrict to 0"
    fi

    # Increase perf buffer size limit from default (~516KB) to 256MB
    # This allows perf to use larger buffers, reducing wakeup frequency
    if [ -w /proc/sys/kernel/perf_event_mlock_kb ]; then
        OLD_LIMIT=$(cat /proc/sys/kernel/perf_event_mlock_kb)
        echo 262144 > /proc/sys/kernel/perf_event_mlock_kb
        NEW_LIMIT=$(cat /proc/sys/kernel/perf_event_mlock_kb)
        echo "Set perf_event_mlock_kb: ${OLD_LIMIT} KB → ${NEW_LIMIT} KB (~$((NEW_LIMIT / 1024)) MB)"
    else
        echo "Warning: Cannot increase perf_event_mlock_kb (buffer size will be limited)"
    fi
'

# Find the op-reth process PID
echo "[2/5] Finding op-reth process..."
RETH_PID=$(docker exec "$CONTAINER" sh -c 'pgrep -f "op-reth node" | head -1')

if [ -z "$RETH_PID" ]; then
    echo "Error: Could not find op-reth process in container"
    exit 1
fi

echo "Found op-reth process with PID: $RETH_PID"

# Find the best available perf binary
KERNEL_VERSION=$(docker exec "$CONTAINER" uname -r | cut -d'.' -f1-2)
echo "Container kernel version: $KERNEL_VERSION"

# Get list of all available perf binaries in the container
# Check both /usr/local/bin and /usr/bin
AVAILABLE_PERFS=$(docker exec "$CONTAINER" sh -c 'ls /usr/local/bin/perf* /usr/bin/perf* 2>/dev/null | grep -E "perf_[0-9]" | sort -u || true')

if [ -n "$AVAILABLE_PERFS" ]; then
    echo "Available perf versions in container:"
    echo "$AVAILABLE_PERFS" | while read -r p; do echo "  - $p"; done

    # Try to find the best match for kernel version
    # Priority: exact match > closest match > highest version
    PERF_BIN=$(docker exec "$CONTAINER" sh -c "
        # Try exact kernel version match in /usr/local/bin first
        if [ -f /usr/local/bin/perf_${KERNEL_VERSION} ]; then
            echo /usr/local/bin/perf_${KERNEL_VERSION}
        elif [ -f /usr/bin/perf_${KERNEL_VERSION} ]; then
            echo /usr/bin/perf_${KERNEL_VERSION}
        else
            # Use highest available version as fallback
            find /usr/local/bin /usr/bin -name 'perf_*' -type f -o -type l 2>/dev/null | \
            grep -E 'perf_[0-9]+\.[0-9]+' | sort -V | tail -1
        fi
    ")

    if [ -n "$PERF_BIN" ]; then
        PERF_VERSION=$(basename "$PERF_BIN" | sed 's/perf_//')
        if [ "$PERF_VERSION" = "$KERNEL_VERSION" ]; then
            echo "✓ Found exact match: perf_${PERF_VERSION} for kernel ${KERNEL_VERSION}"
        else
            echo "⚠ Using perf_${PERF_VERSION} for kernel ${KERNEL_VERSION} (closest available)"
        fi
    fi
else
    echo "No versioned perf binaries found, checking for generic 'perf'..."
fi

# Final fallback to generic 'perf'
if [ -z "$PERF_BIN" ]; then
    PERF_BIN=$(docker exec "$CONTAINER" sh -c 'command -v perf 2>/dev/null || find /usr/local/bin /usr/bin -name "perf" -type f -o -type l 2>/dev/null | head -1 || echo ""')
fi

if [ -z "$PERF_BIN" ]; then
    echo "Error: No perf binary found in container"
    echo "Please rebuild the container with: ./scripts/build-reth-with-profiling.sh"
    exit 1
fi

echo "Selected perf binary: $PERF_BIN"

# Print perf version for verification
PERF_VERSION_OUTPUT=$(docker exec "$CONTAINER" sh -c "$PERF_BIN --version 2>&1" || echo "Unable to get version")
echo "Perf version: $PERF_VERSION_OUTPUT"

# Check available events
echo "[3/5] Checking available off-CPU events..."
AVAILABLE_EVENTS=$(docker exec "$CONTAINER" sh -c "$PERF_BIN list 2>&1 | grep -E 'sched:|block:|writeback:|syscalls:'" || echo "")

if [ -z "$AVAILABLE_EVENTS" ]; then
    echo "Warning: Could not query available events, will attempt profiling anyway"
else
    echo "Sample of available off-CPU events:"
    echo "$AVAILABLE_EVENTS" | head -10
fi

# Record off-CPU profile with perf
echo "[4/5] Recording off-CPU profile for ${DURATION}s with perf..."
echo "Events to capture:"
echo "$EVENTS" | tr ' ' '\n' | sed 's/^/  - /'
echo ""

# Build perf record command with events from config file
PERF_EVENT_ARGS=""
for event in $EVENTS; do
    PERF_EVENT_ARGS="$PERF_EVENT_ARGS -e $event"
done

docker exec "$CONTAINER" sh -c "
    cd /profiling && \
    $PERF_BIN record $PERF_EVENT_ARGS \
                    -p $RETH_PID \
                    -g \
                    -o perf-offcpu.data \
                    -- sleep ${DURATION}
"

echo ""

# Generate perf script output with symbols (optional)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

if [ "$SKIP_SCRIPT" = "true" ]; then
    echo "[5/5] Skipping script generation (SKIP_SCRIPT=true)"
    echo ""

    # Copy only the data file
    echo "[6/6] Copying profile data from container..."
    docker cp "$CONTAINER:/profiling/perf-offcpu.data" "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.data" 2>/dev/null || echo "Warning: Could not copy perf-offcpu.data"

    # Clean up in container
    docker exec "$CONTAINER" sh -c 'rm -f /profiling/perf-offcpu.data' 2>/dev/null || true

    DATA_SIZE=$(du -h "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.data" | cut -f1)
    echo ""
    echo "Off-CPU profile data collected successfully!"
    echo "  - perf-offcpu.data: $OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.data ($DATA_SIZE)"
    echo ""
    echo "To analyze the data:"
    echo "  1. Copy to container: docker cp $OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.data $CONTAINER:/profiling/perf-offcpu.data"
    echo "  2. View with perf report: docker exec -it $CONTAINER $PERF_BIN report -i /profiling/perf-offcpu.data"
    echo "  3. Or generate script later: docker exec $CONTAINER $PERF_BIN script -i /profiling/perf-offcpu.data > $OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script"
    echo ""
else
    echo "[5/5] Generating symbolicated output..."
    docker exec "$CONTAINER" sh -c "
        cd /profiling && \
        $PERF_BIN script -i perf-offcpu.data > perf-offcpu.script
    "

    # Copy profile data from container
    echo "[6/6] Copying profile data from container..."
    docker cp "$CONTAINER:/profiling/perf-offcpu.data" "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.data" 2>/dev/null || echo "Warning: Could not copy perf-offcpu.data"
    docker cp "$CONTAINER:/profiling/perf-offcpu.script" "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script" 2>/dev/null || echo "Warning: Could not copy perf-offcpu.script"

    # Clean up in container
    docker exec "$CONTAINER" sh -c 'rm -f /profiling/perf-offcpu.data /profiling/perf-offcpu.script' 2>/dev/null || true

    SCRIPT_SIZE=$(du -h "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script" | cut -f1)
    echo ""
    echo "Off-CPU profile data collected successfully!"
    echo "  - perf-offcpu.data: $OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.data"
    echo "  - perf-offcpu.script: $OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script ($SCRIPT_SIZE)"
    echo ""
fi

if [ -f "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.data" ]; then

    # Generate summary statistics
    echo "=== Off-CPU Event Summary ==="
    echo ""

    # Detect which event categories were configured
    HAS_FUTEX=$(echo "$EVENTS" | grep -q "futex" && echo "true" || echo "false")
    HAS_IO=$(echo "$EVENTS" | grep -qE "(sys_enter_read|sys_enter_write)" && echo "true" || echo "false")
    HAS_SCHED=$(echo "$EVENTS" | grep -q "sched_switch" && echo "true" || echo "false")
    HAS_BLOCK=$(echo "$EVENTS" | grep -q "block:" && echo "true" || echo "false")
    HAS_PAGEFAULT=$(echo "$EVENTS" | grep -qE "(major-faults|minor-faults|page-faults)" && echo "true" || echo "false")
    HAS_VMSCAN=$(echo "$EVENTS" | grep -q "vmscan:" && echo "true" || echo "false")

    # Only show sections for configured events
    if [ "$HAS_FUTEX" = "true" ]; then
    echo "Lock Contention (futex syscalls):"
    FUTEX_ENTER=$(grep -c "syscalls:sys_enter_futex" "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script" 2>/dev/null || true)
    FUTEX_EXIT=$(grep -c "syscalls:sys_exit_futex" "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script" 2>/dev/null || true)
    FUTEX_WAIT_ENTER=$(grep -c "syscalls:sys_enter_futex_wait" "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script" 2>/dev/null || true)
    FUTEX_WAIT_EXIT=$(grep -c "syscalls:sys_exit_futex_wait" "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script" 2>/dev/null || true)
    # Strip any whitespace/newlines from counts and set default to 0
    FUTEX_ENTER=$(echo "$FUTEX_ENTER" | tr -d '\n\r ' | grep -E '^[0-9]+$' || echo "0")
    FUTEX_EXIT=$(echo "$FUTEX_EXIT" | tr -d '\n\r ' | grep -E '^[0-9]+$' || echo "0")
    FUTEX_WAIT_ENTER=$(echo "$FUTEX_WAIT_ENTER" | tr -d '\n\r ' | grep -E '^[0-9]+$' || echo "0")
    FUTEX_WAIT_EXIT=$(echo "$FUTEX_WAIT_EXIT" | tr -d '\n\r ' | grep -E '^[0-9]+$' || echo "0")
    echo "  futex calls:      $FUTEX_ENTER"
    echo "  futex returns:    $FUTEX_EXIT"
    echo "  futex_wait calls: $FUTEX_WAIT_ENTER"
    echo "  futex_wait ret:   $FUTEX_WAIT_EXIT"
    TOTAL_FUTEX=$((FUTEX_ENTER + FUTEX_WAIT_ENTER))
    if [ "$TOTAL_FUTEX" -gt 0 ]; then
        echo "  → Lock contention detected! Check stack traces for Mutex/RwLock calls"
    fi
    echo ""
    fi

    if [ "$HAS_IO" = "true" ]; then
    echo "I/O Operations:"
    READ_COUNT=$(grep -c "syscalls:sys_enter_read" "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script" 2>/dev/null || true)
    WRITE_COUNT=$(grep -c "syscalls:sys_enter_write" "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script" 2>/dev/null || true)
    FSYNC_COUNT=$(grep -c "syscalls:sys_enter_fsync" "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script" 2>/dev/null || true)
    FDATASYNC_COUNT=$(grep -c "syscalls:sys_enter_fdatasync" "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script" 2>/dev/null || true)
    # Ensure numeric values (strip whitespace and default to 0 if empty)
    READ_COUNT=$(echo "$READ_COUNT" | tr -d '\n\r ' | grep -E '^[0-9]+$' || echo "0")
    WRITE_COUNT=$(echo "$WRITE_COUNT" | tr -d '\n\r ' | grep -E '^[0-9]+$' || echo "0")
    FSYNC_COUNT=$(echo "$FSYNC_COUNT" | tr -d '\n\r ' | grep -E '^[0-9]+$' || echo "0")
    FDATASYNC_COUNT=$(echo "$FDATASYNC_COUNT" | tr -d '\n\r ' | grep -E '^[0-9]+$' || echo "0")
    echo "  read syscalls:     $READ_COUNT"
    echo "  write syscalls:    $WRITE_COUNT"
    echo "  fsync calls:       $FSYNC_COUNT"
    echo "  fdatasync calls:   $FDATASYNC_COUNT"
    echo ""
    fi

    if [ "$HAS_SCHED" = "true" ]; then
    echo "Scheduler context switches:"
    SCHED_SWITCH=$(grep -c "sched:sched_switch" "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script" 2>/dev/null || true)
    # Ensure numeric value (strip whitespace and default to 0 if empty)
    SCHED_SWITCH=$(echo "$SCHED_SWITCH" | tr -d '\n\r ' | grep -E '^[0-9]+$' || echo "0")
    echo "  $SCHED_SWITCH"
    echo ""
    fi

    if [ "$HAS_BLOCK" = "true" ]; then
    echo "Block I/O operations:"
    BLOCK_ISSUE=$(grep -c "block:block_rq_issue" "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script" 2>/dev/null || true)
    BLOCK_COMPLETE=$(grep -c "block:block_rq_complete" "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script" 2>/dev/null || true)
    # Ensure numeric values (strip whitespace and default to 0 if empty)
    BLOCK_ISSUE=$(echo "$BLOCK_ISSUE" | tr -d '\n\r ' | grep -E '^[0-9]+$' || echo "0")
    BLOCK_COMPLETE=$(echo "$BLOCK_COMPLETE" | tr -d '\n\r ' | grep -E '^[0-9]+$' || echo "0")
    echo "  requests issued:    $BLOCK_ISSUE"
    echo "  requests completed: $BLOCK_COMPLETE"
    echo ""
    fi

    if [ "$HAS_PAGEFAULT" = "true" ]; then
    # Page faults (mmap'd I/O)
    MAJOR_FAULTS=$(grep -c "major-faults:" "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script" 2>/dev/null || true)
    MINOR_FAULTS=$(grep -c "minor-faults:" "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script" 2>/dev/null || true)
    # Ensure numeric values (strip whitespace and default to 0 if empty)
    MAJOR_FAULTS=$(echo "$MAJOR_FAULTS" | tr -d '\n\r ' | grep -E '^[0-9]+$' || echo "0")
    MINOR_FAULTS=$(echo "$MINOR_FAULTS" | tr -d '\n\r ' | grep -E '^[0-9]+$' || echo "0")
    if [ "$MAJOR_FAULTS" != "0" ] || [ "$MINOR_FAULTS" != "0" ]; then
        echo "Page faults (memory-mapped I/O):"
        echo "  major faults:      $MAJOR_FAULTS (disk reads)"
        echo "  minor faults:      $MINOR_FAULTS (RAM hits)"
        TOTAL_FAULTS=$((MAJOR_FAULTS + MINOR_FAULTS))
        if [ "$TOTAL_FAULTS" -gt 0 ]; then
            CACHE_HIT_RATE=$(echo "scale=1; $MINOR_FAULTS * 100 / $TOTAL_FAULTS" | bc)
            echo "  cache hit rate:    ${CACHE_HIT_RATE}%"
        fi
        if [ "$MAJOR_FAULTS" -gt 0 ]; then
            MAJOR_FAULT_MB=$(echo "scale=2; $MAJOR_FAULTS * 4 / 1024" | bc)
            echo "  → $MAJOR_FAULTS major faults = ~${MAJOR_FAULT_MB} MB read from disk via mmap"
            echo "    Check stack traces to see which reth functions access mmap'd data"
        fi
        echo ""
    else
        echo "Page faults (memory-mapped I/O): None detected"
        echo ""
    fi
    fi

    if [ "$HAS_VMSCAN" = "true" ]; then
    # Memory pressure
    DIRECT_RECLAIM=$(grep -c "vmscan:mm_vmscan_direct_reclaim_begin" "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script" 2>/dev/null || true)
    KSWAPD_WAKE=$(grep -c "vmscan:mm_vmscan_kswapd_wake" "$OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script" 2>/dev/null || true)
    # Ensure numeric values (strip whitespace and default to 0 if empty)
    DIRECT_RECLAIM=$(echo "$DIRECT_RECLAIM" | tr -d '\n\r ' | grep -E '^[0-9]+$' || echo "0")
    KSWAPD_WAKE=$(echo "$KSWAPD_WAKE" | tr -d '\n\r ' | grep -E '^[0-9]+$' || echo "0")
    if [ "$DIRECT_RECLAIM" != "0" ] || [ "$KSWAPD_WAKE" != "0" ]; then
        echo "Memory pressure:"
        echo "  direct reclaims:   $DIRECT_RECLAIM"
        echo "  kswapd wakes:      $KSWAPD_WAKE"
        if [ "$DIRECT_RECLAIM" -gt 0 ]; then
            echo "  → WARNING: Direct reclaim indicates memory pressure!"
            echo "    Reth may be using too much memory, causing page reclamation"
        fi
        echo ""
    else
        echo "Memory pressure: None detected ✓"
        echo ""
    fi
    fi

    # Generate flamegraph automatically
    echo "[7/7] Generating off-CPU flamegraph..."
    if [ -x "./scripts/generate-flamegraph.sh" ]; then
        ./scripts/generate-flamegraph.sh "$CONTAINER" "perf-offcpu-${TIMESTAMP}.script" "offcpu"
    else
        echo "Warning: generate-flamegraph.sh not found or not executable"
        echo "You can manually generate it with: ./scripts/generate-flamegraph.sh $CONTAINER perf-offcpu-${TIMESTAMP}.script offcpu"
    fi

    echo ""
    echo "=== Analysis Tips ==="
    echo ""
    echo "To analyze lock contention:"
    echo "  1. Search for futex calls in the script file:"
    echo "     grep -A 10 'syscalls:sys_enter_futex' $OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script"
    echo "  2. Look for Rust lock symbols in the stack traces:"
    echo "     - std::sync::Mutex::lock"
    echo "     - std::sync::RwLock::read / write"
    echo "     - parking_lot::Mutex::lock"
    echo "     - tokio::sync::RwLock::read / write"
    echo ""
    echo "To analyze off-CPU time with Brendan Gregg's off-CPU tools:"
    echo "  1. Clone flamegraph tools: git clone https://github.com/brendangregg/FlameGraph"
    echo "  2. Process the script file: ./FlameGraph/stackcollapse-perf.pl $OUTPUT_DIR/perf-offcpu-${TIMESTAMP}.script > out.folded"
    echo "  3. Generate off-CPU flamegraph: ./FlameGraph/flamegraph.pl --title='Off-CPU Time' --color=io out.folded > offcpu.svg"
    echo ""
    echo "To view with perf report (interactive):"
    echo "  docker exec -it $CONTAINER $PERF_BIN report -i /profiling/perf-offcpu.data"
    echo ""
    echo "To filter by specific event type:"
    echo "  docker exec -it $CONTAINER $PERF_BIN report -i /profiling/perf-offcpu.data --stdio | grep futex"
    echo ""
else
    echo "Error: Off-CPU profile was not generated successfully"
    exit 1
fi
