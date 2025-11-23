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

# Check for jemalloc symbols (tikv-jemalloc uses _rjem_ prefix)
JEMALLOC_SYMBOLS=$(docker exec "$CONTAINER" sh -c 'nm /usr/local/bin/op-reth 2>/dev/null | grep -c "_rjem_mallctl" || echo 0')
if [ "$JEMALLOC_SYMBOLS" -gt 0 ]; then
    echo "✓ op-reth has tikv-jemalloc statically linked (_rjem_ prefix)"
    MALLCTL_FUNC="_rjem_mallctl"
else
    # Check for standard jemalloc
    JEMALLOC_SYMBOLS=$(docker exec "$CONTAINER" sh -c 'nm /usr/local/bin/op-reth 2>/dev/null | grep -c "je_mallctl" || echo 0')
    if [ "$JEMALLOC_SYMBOLS" -gt 0 ]; then
        echo "✓ op-reth has jemalloc statically linked (je_ prefix)"
        MALLCTL_FUNC="je_mallctl"
    else
        # Check dynamic linking
        if docker exec "$CONTAINER" ldd /usr/local/bin/op-reth 2>/dev/null | grep -q jemalloc; then
            echo "✓ op-reth is dynamically linked with jemalloc"
            MALLCTL_FUNC="mallctl"
        else
            echo "⚠ Warning: Could not find jemalloc symbols"
            echo "  Profiling may not work as expected"
            MALLCTL_FUNC="mallctl"
        fi
    fi
fi

echo "  Using mallctl function: $MALLCTL_FUNC"

# Check if jemalloc profiling is enabled
# Note: tikv-jemalloc uses _RJEM_MALLOC_CONF, not MALLOC_CONF
echo "[3/6] Checking if jemalloc profiling is enabled..."
MALLOC_CONF_SET=$(docker exec "$CONTAINER" sh -c "cat /proc/$RETH_PID/environ 2>/dev/null | tr '\0' '\n' | grep -qE '^_?RJEM_?MALLOC_CONF.*prof:true|^MALLOC_CONF.*prof:true' && echo 'yes' || echo 'no'")

if [ "$MALLOC_CONF_SET" != "yes" ]; then
    echo ""
    echo "❌ ERROR: Jemalloc profiling is not enabled for this process"
    echo ""
    echo "Jemalloc profiling must be enabled when the process starts, not after."
    echo ""
    echo "For tikv-jemalloc (used by Rust/Reth), use _RJEM_MALLOC_CONF:"
    echo ""
    echo "Option 1: Use environment variable (recommended)"
    echo "  Add to docker-compose.yml under op-reth-seq service:"
    echo "    environment:"
    echo "      - JEMALLOC_PROFILING=true"
    echo "  Then restart: docker-compose restart op-reth-seq"
    echo ""
    echo "Option 2: Set _RJEM_MALLOC_CONF directly"
    echo "  Add to docker-compose.yml under op-reth-seq service:"
    echo "    environment:"
    echo "      - _RJEM_MALLOC_CONF=prof:true,prof_prefix:/profiling/jeprof,lg_prof_interval:30"
    echo "  Then restart: docker-compose restart op-reth-seq"
    echo ""
    echo "Note: This requires op-reth to be built with jemalloc profiling support"
    echo "      Build with: --features jemalloc,jemalloc-prof"
    echo "      (or rebuild using: ./scripts/build-reth-with-profiling.sh)"
    echo ""
    exit 1
fi

echo "✓ Jemalloc profiling is enabled"

# Get the actual MALLOC_CONF value
MALLOC_CONF_VALUE=$(docker exec "$CONTAINER" sh -c "cat /proc/$RETH_PID/environ 2>/dev/null | tr '\0' '\n' | grep -E '^_?RJEM_?MALLOC_CONF=|^MALLOC_CONF=' | head -1")
echo "  $MALLOC_CONF_VALUE"

# Verify jemalloc profiling is actually active by checking opt_prof
echo "  Verifying jemalloc profiling is active..."
OPT_PROF=$(docker exec "$CONTAINER" gdb -batch -p "$RETH_PID" -ex 'p (int)_rjem_je_opt_prof' -ex 'quit' 2>&1 | grep '\$' | grep -oE '[0-9]+$' || echo "0")

if [ "$OPT_PROF" != "1" ]; then
    echo "  ⚠ Warning: opt_prof=$OPT_PROF (expected 1)"
    echo "    Jemalloc may not have profiling compiled in"
    echo "    Rebuild with: --features jemalloc,jemalloc-prof"
else
    echo "  ✓ opt_prof=1 (profiling is active)"
fi

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

for i in $(seq 1 $COUNT); do
    echo "Heap dump $i/$COUNT at $(date)"

    # Trigger heap dump using gdb with the correct mallctl function
    GDB_OUTPUT=$(docker exec "$CONTAINER" gdb -batch -p "$RETH_PID" \
        -ex "call (int)$MALLCTL_FUNC(\"prof.dump\", 0, 0, 0, 0)" \
        -ex 'quit' 2>&1)

    # Check if mallctl returned 0 (success)
    if echo "$GDB_OUTPUT" | grep -q '\$.*= 0'; then
        echo "  ✓ Heap dump triggered successfully"
    else
        RETVAL=$(echo "$GDB_OUTPUT" | grep '\$' | grep -oE '[0-9]+$' || echo "unknown")
        echo "  ⚠ mallctl returned: $RETVAL (0=success, 2=ENOENT)"
    fi

    if [ $i -lt $COUNT ]; then
        sleep $INTERVAL
    fi
done

echo "Heap profiling collection completed"

# Check for generated heap files
echo "[5/6] Checking for heap dump files..."
HEAP_FILES=$(docker exec "$CONTAINER" sh -c 'find /profiling -name "*.heap" 2>/dev/null | sort' | tr '\n' ' ')

if [ -z "$HEAP_FILES" ] || [ "$HEAP_FILES" = " " ]; then
    echo "⚠ No heap dump files found in /profiling"
    echo ""
    echo "Checking other locations..."
    docker exec "$CONTAINER" sh -c 'find / -name "*.heap" 2>/dev/null | head -10'
    exit 1
fi

echo "Found heap dump files:"
for f in $HEAP_FILES; do
    SIZE=$(docker exec "$CONTAINER" stat -c%s "$f" 2>/dev/null || echo "?")
    echo "  - $f ($SIZE bytes)"
done

# Process heap dumps
echo "[6/6] Processing heap dumps..."
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Get the latest heap file
LATEST_HEAP=$(echo "$HEAP_FILES" | tr ' ' '\n' | grep -v '^$' | tail -1)
echo "Processing: $LATEST_HEAP"

# Copy heap files to output directory
for heap_file in $HEAP_FILES; do
    if [ -n "$heap_file" ]; then
        filename=$(basename "$heap_file")
        docker cp "$CONTAINER:$heap_file" "$OUTPUT_DIR/${filename}" 2>/dev/null || true
    fi
done

# Generate text report - without symbol resolution (addr2line is too slow)
echo "Generating text report..."

docker exec "$CONTAINER" bash -c '
BASE_HEX=$(cat /proc/'"$RETH_PID"'/maps | grep "op-reth" | head -1 | cut -d"-" -f1)
BASE_DEC=$((0x$BASE_HEX))
HEAP_FILE="'"$LATEST_HEAP"'"

{
echo "=== Jemalloc Heap Profile ==="
echo "Generated: $(date)"
echo "Heap file: $HEAP_FILE"
echo "Base address: 0x$BASE_HEX"
echo ""
echo "Note: Symbol resolution skipped (addr2line is slow for large binaries)"
echo "To resolve symbols manually:"
echo "  1. Subtract base address from stack address"
echo "  2. Run: addr2line -e /usr/local/bin/op-reth -Cf <relative_addr>"
echo ""

# Parse heap file header
head -15 "$HEAP_FILE"
echo ""
echo "=== Top Allocations (by size) ==="
echo ""

# Extract top allocations with relative addresses
awk "/^@/{stack=\$0; getline; if(\$0 ~ /t\*:/) {split(\$0,a,\" \"); bytes=a[3]; gsub(/[^0-9]/,\"\",bytes); if(bytes+0>1000) print bytes, stack}}" "$HEAP_FILE" | sort -rn | head -30 | while read bytes stack; do
    [ -z "$bytes" ] && continue

    # Format bytes nicely
    if [ $bytes -ge 1048576 ]; then
        SIZE_FMT="$((bytes/1048576))MB"
    elif [ $bytes -ge 1024 ]; then
        SIZE_FMT="$((bytes/1024))KB"
    else
        SIZE_FMT="${bytes}B"
    fi
    echo "--- $SIZE_FMT ($bytes bytes) ---"

    # Show relative addresses (ready for addr2line)
    ADDRS=$(echo "$stack" | tr " " "\n" | grep "0x" | head -5)
    for addr in $ADDRS; do
        ADDR_DEC=$((addr))
        REL=$(printf "0x%x" $((ADDR_DEC - BASE_DEC)))
        echo "  $REL"
    done
    echo ""
done
} > /profiling/jemalloc-report.txt
'

# Copy report
docker cp "$CONTAINER:/profiling/jemalloc-report.txt" "$OUTPUT_DIR/jemalloc-${TIMESTAMP}.txt" 2>/dev/null || true

# Skip collapsed stacks generation by default (very slow due to addr2line)
# Users can generate flamegraphs manually if needed
echo "Skipping collapsed stacks generation (use --flamegraph flag to enable)"

# Generate flamegraph if flamegraph.pl is available
if command -v flamegraph.pl &> /dev/null && [ -f "$OUTPUT_DIR/jemalloc-${TIMESTAMP}.folded" ]; then
    echo "Generating flamegraph..."
    flamegraph.pl --title "Jemalloc Heap Profile - $CONTAINER" \
        --countname "bytes" \
        "$OUTPUT_DIR/jemalloc-${TIMESTAMP}.folded" > "$OUTPUT_DIR/jemalloc-${TIMESTAMP}.svg" 2>/dev/null || true
fi

# Clean up in container (but keep heap files for manual analysis)
docker exec "$CONTAINER" sh -c 'rm -f /profiling/jemalloc-report.txt /profiling/jemalloc.folded' 2>/dev/null || true

echo ""
echo "=== Jemalloc profiling completed! ==="
echo ""
echo "Results in $OUTPUT_DIR:"
ls -la "$OUTPUT_DIR"/*.heap "$OUTPUT_DIR"/jemalloc-${TIMESTAMP}.* 2>/dev/null | while read line; do
    echo "  $line"
done

echo ""
if [ -f "$OUTPUT_DIR/jemalloc-${TIMESTAMP}.txt" ]; then
    echo "Top allocations:"
    echo "----------------------------------------"
    head -50 "$OUTPUT_DIR/jemalloc-${TIMESTAMP}.txt"
    echo "----------------------------------------"
    echo ""
    echo "Full report: $OUTPUT_DIR/jemalloc-${TIMESTAMP}.txt"
fi

if [ -f "$OUTPUT_DIR/jemalloc-${TIMESTAMP}.svg" ]; then
    echo "Flamegraph: $OUTPUT_DIR/jemalloc-${TIMESTAMP}.svg"
fi

echo ""
echo "To analyze heap files manually:"
echo "  docker exec $CONTAINER cat $LATEST_HEAP"
