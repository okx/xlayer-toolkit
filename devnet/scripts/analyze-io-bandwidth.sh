#!/bin/bash

set -e

SCRIPT_FILE=${1}

if [ -z "$SCRIPT_FILE" ] || [ ! -f "$SCRIPT_FILE" ]; then
    echo "Usage: $0 <perf-offcpu-script-file>"
    echo ""
    echo "Analyzes I/O bandwidth from perf off-CPU profiling data"
    echo ""
    echo "Example:"
    echo "  $0 ./profiling/op-reth-seq/perf-offcpu-20251201-120000.script"
    exit 1
fi

echo "=== I/O Bandwidth Analysis ==="
echo "Processing: $SCRIPT_FILE"
echo ""

# Extract read/write syscalls with their count parameter
# Format: syscalls:sys_enter_read: fd: X, buf: Y, count: Z

echo "[1/4] Analyzing read operations..."
# Extract hex count values and convert to decimal
# Count both read() and pread64()
READ_TOTAL=$(grep -E 'sys_enter_(read|pread64):' "$SCRIPT_FILE" | \
    sed -n 's/.*count: \(0x[0-9a-fA-F]*\).*/\1/p' | \
    awk '{printf "%d\n", $1}' | \
    awk '{sum+=$1} END {print sum}')

READ_COUNT=$(grep -cE 'sys_enter_(read|pread64):' "$SCRIPT_FILE" || echo "0")
READ_TOTAL=${READ_TOTAL:-0}

if [ "$READ_TOTAL" -gt 0 ]; then
    READ_MB=$(echo "scale=2; $READ_TOTAL / 1048576" | bc)
    READ_AVG=$(echo "scale=2; $READ_TOTAL / $READ_COUNT" | bc)
else
    READ_MB=0
    READ_AVG=0
fi

echo "  Total read calls: $READ_COUNT"
echo "  Total bytes read: $READ_TOTAL bytes ($READ_MB MB)"
echo "  Average read size: $READ_AVG bytes"
echo ""

echo "[2/4] Analyzing write operations..."
# Extract hex count values and convert to decimal
# Count both write() and pwrite64()
WRITE_TOTAL=$(grep -E 'sys_enter_(write|pwrite64):' "$SCRIPT_FILE" | \
    sed -n 's/.*count: \(0x[0-9a-fA-F]*\).*/\1/p' | \
    awk '{printf "%d\n", $1}' | \
    awk '{sum+=$1} END {print sum}')

WRITE_COUNT=$(grep -cE 'sys_enter_(write|pwrite64):' "$SCRIPT_FILE" || echo "0")
WRITE_TOTAL=${WRITE_TOTAL:-0}

if [ "$WRITE_TOTAL" -gt 0 ]; then
    WRITE_MB=$(echo "scale=2; $WRITE_TOTAL / 1048576" | bc)
    WRITE_AVG=$(echo "scale=2; $WRITE_TOTAL / $WRITE_COUNT" | bc)
else
    WRITE_MB=0
    WRITE_AVG=0
fi

echo "  Total write calls: $WRITE_COUNT"
echo "  Total bytes written: $WRITE_TOTAL bytes ($WRITE_MB MB)"
echo "  Average write size: $WRITE_AVG bytes"
echo ""

echo "[3/4] Identifying top I/O sources..."
echo ""
echo "Top functions doing reads (by call count):"
grep -B 15 -E 'sys_enter_(read|pread64):' "$SCRIPT_FILE" | \
    grep 'reth_' | \
    sed 's/^[[:space:]]*//' | \
    sed 's/+0x[0-9a-f]* .*//' | \
    awk '{print $2}' | \
    sort | uniq -c | sort -rn | head -10 | \
    awk '{printf "  %6d calls: %s\n", $1, $2}'

echo ""
echo "Top functions doing writes (by call count):"
grep -B 15 -E 'sys_enter_(write|pwrite64):' "$SCRIPT_FILE" | \
    grep 'reth_' | \
    sed 's/^[[:space:]]*//' | \
    sed 's/+0x[0-9a-f]* .*//' | \
    awk '{print $2}' | \
    sort | uniq -c | sort -rn | head -10 | \
    awk '{printf "  %6d calls: %s\n", $1, $2}'

echo ""
echo "[4/4] Summary"
echo ""
TOTAL_IO=$((READ_TOTAL + WRITE_TOTAL))
TOTAL_IO_MB=$(echo "scale=2; $TOTAL_IO / 1048576" | bc)
echo "Total I/O bandwidth: $TOTAL_IO bytes ($TOTAL_IO_MB MB)"
echo "Read/Write ratio: $READ_MB MB read / $WRITE_MB MB written"

# Get profiling duration from filename if possible
if [[ "$SCRIPT_FILE" =~ perf-offcpu-([0-9]+)-([0-9]+)\.script ]]; then
    echo ""
    echo "Note: To calculate bandwidth per second, divide by profiling duration"
    echo "      If profiled for 60s: $(echo "scale=2; $TOTAL_IO_MB / 60" | bc) MB/s"
fi

echo ""
echo "=== Analysis Complete ==="
