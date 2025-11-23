#!/bin/bash

set -e

# Configuration
CONTAINER=${1:-op-reth-seq}
DURATION=${2:-60}
OUTPUT_DIR="./profiling/${CONTAINER}"

echo "=== Reth Memory Profiling with Jemalloc ==="
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

# Find the op-reth process PID
echo "[1/6] Finding op-reth process..."
RETH_PID=$(docker exec "$CONTAINER" sh -c 'pgrep -f "op-reth node" | head -1')

if [ -z "$RETH_PID" ]; then
    echo "Error: Could not find op-reth process in container"
    exit 1
fi

echo "Found op-reth process with PID: $RETH_PID"

# Check if jemalloc profiling is available
echo "[2/6] Checking jemalloc profiling support..."
docker exec "$CONTAINER" sh -c "
    # Check if op-reth is linked with jemalloc
    if ldd /usr/local/bin/op-reth | grep -q jemalloc; then
        echo '✓ op-reth is linked with jemalloc'
    else
        echo '⚠ Warning: op-reth may not be linked with jemalloc'
        echo '  Profiling may not work as expected'
    fi
"

# Check for jeprof tool
if docker exec "$CONTAINER" which jeprof > /dev/null 2>&1; then
    echo "✓ jeprof tool is available"
    JEPROF_BIN="jeprof"
else
    echo "⚠ jeprof not found, checking for alternatives..."
    # Check for google-pprof or pprof
    if docker exec "$CONTAINER" which google-pprof > /dev/null 2>&1; then
        JEPROF_BIN="google-pprof"
        echo "✓ Using google-pprof"
    elif docker exec "$CONTAINER" which pprof > /dev/null 2>&1; then
        JEPROF_BIN="pprof"
        echo "✓ Using pprof"
    else
        echo "Warning: No heap profiling tool found. Install jeprof/google-pprof for analysis."
        JEPROF_BIN=""
    fi
fi

# Check if jemalloc profiling is enabled
echo "[3/6] Checking if jemalloc profiling is enabled..."
MALLOC_CONF_SET=$(docker exec "$CONTAINER" sh -c "cat /proc/$RETH_PID/environ 2>/dev/null | tr '\0' '\n' | grep -q '^MALLOC_CONF.*prof:true' && echo 'yes' || echo 'no'")

if [ "$MALLOC_CONF_SET" != "yes" ]; then
    echo ""
    echo "❌ ERROR: Jemalloc profiling is not enabled for this process"
    echo ""
    echo "Jemalloc profiling must be enabled when the process starts, not after."
    echo "The MALLOC_CONF environment variable must be set before starting op-reth."
    echo ""
    echo "To enable jemalloc profiling:"
    echo ""
    echo "Option 1: Use environment variable (recommended)"
    echo "  Add to docker-compose.yml under op-reth-seq service:"
    echo "    environment:"
    echo "      - JEMALLOC_PROFILING=true"
    echo "  Then restart: docker-compose restart op-reth-seq"
    echo ""
    echo "Option 2: Set MALLOC_CONF directly"
    echo "  Add to docker-compose.yml under op-reth-seq service:"
    echo "    environment:"
    echo "      - MALLOC_CONF=prof:true,prof_prefix:/profiling/jeprof,lg_prof_interval:30"
    echo "  Then restart: docker-compose restart op-reth-seq"
    echo ""
    echo "Option 3: Edit entrypoint script"
    echo "  Edit: devnet/entrypoint/reth-seq.sh"
    echo "  Add before 'exec op-reth':"
    echo "    export MALLOC_CONF=\"prof:true,prof_prefix:/profiling/jeprof,lg_prof_interval:30\""
    echo "  Then rebuild and restart"
    echo ""
    echo "Then run this script again."
    echo ""
    echo "Note: This requires op-reth to be built with jemalloc profiling support"
    echo "      Build with: --features jemalloc-prof"
    echo "      (or rebuild using: ./scripts/build-reth-with-profiling.sh)"
    echo ""
    exit 1
fi

echo "✓ Jemalloc profiling is enabled (MALLOC_CONF detected)"

# Verify jemalloc profiling support
echo "Verifying jemalloc profiling support..."
MALLOC_CONF_VALUE=$(docker exec "$CONTAINER" sh -c "cat /proc/$RETH_PID/environ 2>/dev/null | tr '\0' '\n' | grep '^MALLOC_CONF=' | cut -d= -f2-")
echo "  MALLOC_CONF: $MALLOC_CONF_VALUE"

# Try to verify if jemalloc has profiling enabled by checking mallctl availability
echo "  Testing mallctl availability..."
docker exec "$CONTAINER" sh -c "
    gdb -batch -ex \"attach $RETH_PID\" -ex \"info functions mallctl\" -ex \"detach\" -ex \"quit\" 2>&1 | grep -q 'mallctl' && echo '    ✓ mallctl function found' || echo '    ⚠ mallctl function not found (jemalloc may not have profiling support)'
" || echo "    ⚠ Could not verify mallctl"

# Create a wrapper script to dump heap profile
docker exec "$CONTAINER" sh -c "
cat > /profiling/dump-heap.sh <<'SCRIPT'
#!/bin/bash
# Trigger heap dump via jemalloc
# This requires jemalloc to be built with --enable-prof

RETH_PID=\$1
INTERVAL=\$2
COUNT=\$3

echo \"Dumping heap profiles every \${INTERVAL}s for \${COUNT} times...\"

for i in \$(seq 1 \$COUNT); do
    echo \"Heap dump \$i/\$COUNT at \$(date)\"
    
    # Method 1: Try to trigger heap dump using gdb to call mallctl
    # Note: This requires jemalloc to be built with --enable-prof
    echo \"  Attempting to trigger heap dump via mallctl...\"
    GDB_OUTPUT=\$(gdb -batch -ex \"attach \$RETH_PID\" -ex \"call (int)mallctl('prof.dump', NULL, NULL, NULL, 0)\" -ex \"detach\" -ex \"quit\" 2>&1)
    GDB_EXIT=\$?
    
    if [ \$GDB_EXIT -eq 0 ]; then
        # Check if mallctl returned 0 (success)
        if echo \"\$GDB_OUTPUT\" | grep -q '= 0'; then
            echo \"  ✓ Heap dump triggered successfully\"
        else
            echo \"  ⚠ mallctl call may have failed\"
            echo \"  GDB output: \$GDB_OUTPUT\" | head -5
        fi
    else
        echo \"  ⚠ GDB attach failed, trying alternative method...\"
        # Method 2: Try to send signal to trigger dump (if supported)
        # Some jemalloc builds support SIGUSR2 to dump heap
        kill -USR2 \$RETH_PID 2>/dev/null && echo \"  ✓ Sent SIGUSR2 signal\" || echo \"  ⚠ SIGUSR2 not supported\"
    fi

    sleep \$INTERVAL
done

echo \"Heap profiling collection completed\"
SCRIPT

chmod +x /profiling/dump-heap.sh
"

# Calculate number of samples
INTERVAL=10
COUNT=$((DURATION / INTERVAL))
if [ $COUNT -lt 1 ]; then
    COUNT=1
    INTERVAL=$DURATION
fi

echo "Will collect $COUNT heap samples at ${INTERVAL}s intervals"

# Run heap dumping
echo "[4/6] Collecting heap profiles for ${DURATION}s..."
docker exec "$CONTAINER" /profiling/dump-heap.sh "$RETH_PID" "$INTERVAL" "$COUNT"

# Check for generated heap files
echo "[5/6] Checking for heap dump files..."
# Check multiple possible locations where jemalloc might create heap dumps
HEAP_FILES=$(docker exec "$CONTAINER" sh -c '
    find /profiling -name "*.heap" -o -name "jeprof*" 2>/dev/null
    find /tmp -name "*.heap" -o -name "jeprof*" 2>/dev/null
    ls /profiling/jeprof*.heap 2>/dev/null
    ls /tmp/jeprof*.heap 2>/dev/null
' | sort -u | tr '\n' ' ')

if [ -z "$HEAP_FILES" ] || [ "$HEAP_FILES" = " " ]; then
    HEAP_FILES=""
fi

if [ -z "$HEAP_FILES" ]; then
    echo "⚠ No heap dump files found."
    echo ""
    echo "Possible reasons:"
    echo "  1. Jemalloc was not built with profiling support (--enable-prof)"
    echo "  2. The mallctl('prof.dump') call failed"
    echo "  3. Heap dumps are being created in a different location"
    echo ""
    echo "Checking for heap files in common locations..."
    docker exec "$CONTAINER" sh -c '
        echo "Checking /profiling:"
        ls -la /profiling/*.heap /profiling/jeprof* 2>/dev/null || echo "  No files in /profiling"
        echo ""
        echo "Checking /tmp:"
        ls -la /tmp/*.heap /tmp/jeprof* 2>/dev/null || echo "  No files in /tmp"
        echo ""
        echo "Checking current directory:"
        ls -la *.heap jeprof* 2>/dev/null || echo "  No files in current directory"
    '
    echo ""
    echo "Attempting to create heap snapshot manually..."

    # Try to get heap info via jemalloc stats
    docker exec "$CONTAINER" sh -c "
        # Create a manual heap snapshot by reading /proc/PID/smaps
        cat > /profiling/memory-snapshot.txt <<EOF
=== Memory Snapshot at \$(date) ===
PID: $RETH_PID
EOF

        if [ -f /proc/$RETH_PID/status ]; then
            echo '' >> /profiling/memory-snapshot.txt
            echo '=== Process Status ===' >> /profiling/memory-snapshot.txt
            grep -E 'VmSize|VmRSS|VmData|VmStk|VmExe|VmLib' /proc/$RETH_PID/status >> /profiling/memory-snapshot.txt
        fi

        if [ -f /proc/$RETH_PID/smaps_rollup ]; then
            echo '' >> /profiling/memory-snapshot.txt
            echo '=== Memory Map Summary ===' >> /profiling/memory-snapshot.txt
            cat /proc/$RETH_PID/smaps_rollup >> /profiling/memory-snapshot.txt
        fi

        echo '' >> /profiling/memory-snapshot.txt
        echo '=== Memory Map Details ===' >> /profiling/memory-snapshot.txt
        cat /proc/$RETH_PID/maps >> /profiling/memory-snapshot.txt 2>/dev/null || true
    " || echo "Warning: Could not create memory snapshot"

    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    docker cp "$CONTAINER:/profiling/memory-snapshot.txt" "$OUTPUT_DIR/jemalloc-${TIMESTAMP}-snapshot.txt" 2>/dev/null

    echo ""
    echo "⚠ Created memory snapshot (no jemalloc heap dumps available)"
    echo "  - Snapshot: $OUTPUT_DIR/jemalloc-${TIMESTAMP}-snapshot.txt"
    echo ""
    echo "Why heap dumps weren't created:"
    echo ""
    echo "  MALLOC_CONF is set correctly, but heap dump files aren't being generated."
    echo "  This usually means jemalloc was NOT built with profiling support."
    echo ""
    echo "  Jemalloc profiling requires:"
    echo "    1. MALLOC_CONF set (✓ you have this)"
    echo "    2. Reth built with --features jemalloc-prof (✗ likely missing)"
    echo ""
    echo "  To fix this, you need to rebuild reth with jemalloc profiling enabled:"
    echo "    1. Rebuild the reth image: ./scripts/build-reth-with-profiling.sh"
    echo "    2. This will build with --features jemalloc-prof automatically"
    echo "    3. Restart the container"
    echo ""
    echo "  Alternative: Use heaptrack or valgrind massif for memory profiling"
    echo "    (though heaptrack won't work with jemalloc either)"
    echo ""

    if [ -f "$OUTPUT_DIR/jemalloc-${TIMESTAMP}-snapshot.txt" ]; then
        echo "Memory usage summary:"
        echo "----------------------------------------"
        grep -E 'VmSize|VmRSS|VmData|Rss:|Pss:' "$OUTPUT_DIR/jemalloc-${TIMESTAMP}-snapshot.txt" | head -20
        echo "----------------------------------------"
    fi

    exit 0
fi

echo "Found heap dump files:"
echo "$HEAP_FILES" | while read -r f; do echo "  - $f"; done

# Process heap dumps
echo "[6/6] Processing heap dumps..."
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Get the latest heap file
LATEST_HEAP=$(echo "$HEAP_FILES" | tail -1)
echo "Processing: $LATEST_HEAP"

# Copy heap files
docker exec "$CONTAINER" sh -c 'ls /profiling/*.heap 2>/dev/null || ls /tmp/jeprof.*.heap 2>/dev/null' | while read -r heap_file; do
    filename=$(basename "$heap_file")
    docker cp "$CONTAINER:$heap_file" "$OUTPUT_DIR/jemalloc-${TIMESTAMP}-${filename}" 2>/dev/null || true
done

if [ -n "$JEPROF_BIN" ]; then
    # Generate text report
    echo "Generating text report..."
    docker exec "$CONTAINER" sh -c "
        $JEPROF_BIN --text /usr/local/bin/op-reth '$LATEST_HEAP' > /profiling/jemalloc-report.txt 2>/dev/null
    " || echo "Warning: Could not generate text report"

    # Generate collapsed stacks for flamegraph
    echo "Generating collapsed stacks..."
    docker exec "$CONTAINER" sh -c "
        $JEPROF_BIN --collapsed /usr/local/bin/op-reth '$LATEST_HEAP' > /profiling/jemalloc.folded 2>/dev/null
    " || echo "Warning: Could not generate collapsed stacks"

    # Copy reports
    docker cp "$CONTAINER:/profiling/jemalloc-report.txt" "$OUTPUT_DIR/jemalloc-${TIMESTAMP}.txt" 2>/dev/null || true
    docker cp "$CONTAINER:/profiling/jemalloc.folded" "$OUTPUT_DIR/jemalloc-${TIMESTAMP}.folded" 2>/dev/null || true

    # Generate flamegraph if script available
    if [ -f "$OUTPUT_DIR/jemalloc-${TIMESTAMP}.folded" ] && [ -x "./scripts/generate-memory-flamegraph.sh" ]; then
        echo "[7/7] Generating memory flamegraph..."
        ./scripts/generate-memory-flamegraph.sh "$CONTAINER" "jemalloc-${TIMESTAMP}.folded" "jemalloc"
    fi
fi

# Clean up in container
docker exec "$CONTAINER" sh -c 'rm -f /profiling/*.heap /profiling/jemalloc-report.txt /profiling/jemalloc.folded /profiling/dump-heap.sh' 2>/dev/null || true

echo ""
echo "Jemalloc profiling completed!"
echo ""

if [ -f "$OUTPUT_DIR/jemalloc-${TIMESTAMP}.txt" ]; then
    REPORT_SIZE=$(du -h "$OUTPUT_DIR/jemalloc-${TIMESTAMP}.txt" | cut -f1)
    echo "Results:"
    echo "  - Report: $OUTPUT_DIR/jemalloc-${TIMESTAMP}.txt ($REPORT_SIZE)"

    if [ -f "$OUTPUT_DIR/jemalloc-${TIMESTAMP}.folded" ]; then
        echo "  - Folded stacks: $OUTPUT_DIR/jemalloc-${TIMESTAMP}.folded"
    fi

    if [ -f "$OUTPUT_DIR/jemalloc-${TIMESTAMP}-allocations.svg" ]; then
        echo "  - Flamegraph: $OUTPUT_DIR/jemalloc-${TIMESTAMP}-allocations.svg"
    fi

    echo ""
    echo "Top allocation sites:"
    echo "----------------------------------------"
    head -30 "$OUTPUT_DIR/jemalloc-${TIMESTAMP}.txt"
    echo "----------------------------------------"
    echo ""
    echo "For full report: cat $OUTPUT_DIR/jemalloc-${TIMESTAMP}.txt"

    if [ -f "$OUTPUT_DIR/jemalloc-${TIMESTAMP}-allocations.svg" ]; then
        echo "View flamegraph: open $OUTPUT_DIR/jemalloc-${TIMESTAMP}-allocations.svg"
    fi
fi
