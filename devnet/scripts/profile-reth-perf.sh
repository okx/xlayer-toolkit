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

# Find the actual perf binary (may be version-specific)
PERF_BIN=$(docker exec "$CONTAINER" sh -c 'which perf_5.10 2>/dev/null || find /usr/bin -name "perf_*" -type f | head -1')
if [ -z "$PERF_BIN" ]; then
    PERF_BIN="perf"
fi
echo "Using perf binary: $PERF_BIN"

# Record profile with perf
echo "[3/5] Recording CPU profile for ${DURATION}s with perf..."
echo "Collecting call graph data with symbols..."

docker exec "$CONTAINER" sh -c "
    cd /profiling && \
    $PERF_BIN record -F 999 -p $RETH_PID -g --call-graph fp -o perf.data -- sleep ${DURATION}
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
    echo "Done!"
    echo ""
    echo "Profile data saved:"
    echo "  - perf.data: $OUTPUT_DIR/perf-${TIMESTAMP}.data"
    echo "  - perf.script: $OUTPUT_DIR/perf-${TIMESTAMP}.script ($SCRIPT_SIZE)"
    echo ""
    echo "Next steps:"
    echo "  1. Generate flamegraph: ./scripts/generate-flamegraph.sh $CONTAINER perf-${TIMESTAMP}.script"
    echo "  2. View perf report: docker exec $CONTAINER perf report -i /profiling/perf.data"
else
    echo "Error: Profile was not generated successfully"
    exit 1
fi
