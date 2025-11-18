#!/bin/bash

set -e

# Configuration
CONTAINER=${1:-op-reth-seq}
DURATION=${2:-60}
OUTPUT_DIR="./profiling/${CONTAINER}"

echo "=== Reth CPU Profiling with perf ==="
echo "Container: $CONTAINER"
echo "Duration: ${DURATION}s"
echo "Output Directory: $OUTPUT_DIR"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

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

# Record profile with perf
echo "[3/5] Recording CPU profile for ${DURATION}s with perf..."
echo "Collecting call graph data with symbols..."

docker exec "$CONTAINER" sh -c "
    cd /profiling && \
    $PERF_BIN record -F 999 -e cycles:u -p $RETH_PID -g --call-graph fp -o perf.data -- sleep ${DURATION}
"

# Generate perf script output with symbols
echo "[4/5] Generating symbolicated output..."
docker exec "$CONTAINER" sh -c "
    cd /profiling && \
    $PERF_BIN script -i perf.data > perf.script
"

# Copy profile data from container
echo "[5/5] Copying profile data from container..."
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
docker cp "$CONTAINER:/profiling/perf.data" "$OUTPUT_DIR/perf-${TIMESTAMP}.data" 2>/dev/null || echo "Warning: Could not copy perf.data"
docker cp "$CONTAINER:/profiling/perf.script" "$OUTPUT_DIR/perf-${TIMESTAMP}.script" 2>/dev/null || echo "Warning: Could not copy perf.script"

# Clean up in container
docker exec "$CONTAINER" sh -c 'rm -f /profiling/perf.data /profiling/perf.script' 2>/dev/null || true

if [ -f "$OUTPUT_DIR/perf-${TIMESTAMP}.script" ]; then
    SCRIPT_SIZE=$(du -h "$OUTPUT_DIR/perf-${TIMESTAMP}.script" | cut -f1)
    echo ""
    echo "Profile data collected successfully!"
    echo "  - perf.data: $OUTPUT_DIR/perf-${TIMESTAMP}.data"
    echo "  - perf.script: $OUTPUT_DIR/perf-${TIMESTAMP}.script ($SCRIPT_SIZE)"
    echo ""

    # Generate flamegraph automatically
    echo "[6/6] Generating flamegraph..."
    if [ -x "./scripts/generate-flamegraph.sh" ]; then
        ./scripts/generate-flamegraph.sh "$CONTAINER" "perf-${TIMESTAMP}.script"
    else
        echo "Warning: generate-flamegraph.sh not found or not executable"
        echo "You can manually generate it with: ./scripts/generate-flamegraph.sh $CONTAINER perf-${TIMESTAMP}.script"
    fi
else
    echo "Error: Profile was not generated successfully"
    exit 1
fi
