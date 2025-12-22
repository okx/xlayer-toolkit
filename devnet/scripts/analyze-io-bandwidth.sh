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

# Detect perf output format by checking a sample line
SAMPLE_LINE=$(grep -m1 -E 'sys_enter_(read|pread64):' "$SCRIPT_FILE" 2>/dev/null || echo "")
if [ -n "$SAMPLE_LINE" ]; then
    echo "Detected perf syscall format (sample line):"
    echo "  $SAMPLE_LINE" | head -c 200
    echo ""
    echo ""
fi

# Extract read/write syscalls with their count parameter
# Format variations:
#   syscalls:sys_enter_read: fd: X, buf: Y, count: 0x1234  (hex)
#   syscalls:sys_enter_read: fd: X, buf: Y, count: 4660   (decimal)
#   syscalls:sys_enter_read: fd=X buf=Y count=0x1234     (equals sign format)

echo "[1/4] Analyzing read operations..."
# Extract count/len values and convert to decimal
# Count both read() and pread64()
# Support multiple perf output formats:
#   Format 1: count: 0x12345 (hex with 0x prefix)
#   Format 2: count: 12345 (decimal)
#   Format 3: count=0x12345 or count=12345 (equals sign)
#   Format 4: len: or len= (alternative field name)
#   Format 5: nbyte: or nbyte= (another alternative)
# Note: Using -E for extended regex (works on both BSD/macOS and GNU sed)
READ_TOTAL=$(grep -E 'sys_enter_(read|pread64):' "$SCRIPT_FILE" | \
    sed -E -n 's/.*(count|len|nbyte)[=:][[:space:]]*(0x[0-9a-fA-F]+|[0-9]+).*/\2/p' | \
    awk 'BEGIN {
        # Build hex digit lookup table (portable, no strtonum needed)
        for (i = 0; i <= 9; i++) hex[sprintf("%d", i)] = i
        hex["a"] = 10; hex["b"] = 11; hex["c"] = 12
        hex["d"] = 13; hex["e"] = 14; hex["f"] = 15
        hex["A"] = 10; hex["B"] = 11; hex["C"] = 12
        hex["D"] = 13; hex["E"] = 14; hex["F"] = 15
    }
    {
        val = $1
        if (substr(val, 1, 2) == "0x" || substr(val, 1, 2) == "0X") {
            # Hex value - convert to decimal manually
            hexstr = substr(val, 3)
            dec = 0
            for (i = 1; i <= length(hexstr); i++) {
                dec = dec * 16 + hex[substr(hexstr, i, 1)]
            }
            sum += dec
        } else if (val ~ /^[0-9]+$/) {
            # Decimal value
            sum += val
        }
    }
    END {print sum+0}')

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
# Extract count/len values and convert to decimal
# Count both write() and pwrite64()
# Support multiple perf output formats (same as reads)
# Note: Using -E for extended regex (works on both BSD/macOS and GNU sed)
WRITE_TOTAL=$(grep -E 'sys_enter_(write|pwrite64):' "$SCRIPT_FILE" | \
    sed -E -n 's/.*(count|len|nbyte)[=:][[:space:]]*(0x[0-9a-fA-F]+|[0-9]+).*/\2/p' | \
    awk 'BEGIN {
        # Build hex digit lookup table (portable, no strtonum needed)
        for (i = 0; i <= 9; i++) hex[sprintf("%d", i)] = i
        hex["a"] = 10; hex["b"] = 11; hex["c"] = 12
        hex["d"] = 13; hex["e"] = 14; hex["f"] = 15
        hex["A"] = 10; hex["B"] = 11; hex["C"] = 12
        hex["D"] = 13; hex["E"] = 14; hex["F"] = 15
    }
    {
        val = $1
        if (substr(val, 1, 2) == "0x" || substr(val, 1, 2) == "0X") {
            # Hex value - convert to decimal manually
            hexstr = substr(val, 3)
            dec = 0
            for (i = 1; i <= length(hexstr); i++) {
                dec = dec * 16 + hex[substr(hexstr, i, 1)]
            }
            sum += dec
        } else if (val ~ /^[0-9]+$/) {
            # Decimal value
            sum += val
        }
    }
    END {print sum+0}')

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

# Diagnostic output if bytes are 0 but syscalls were detected
TOTAL_CALLS=$((READ_COUNT + WRITE_COUNT))
if [ "$TOTAL_IO" -eq 0 ] && [ "$TOTAL_CALLS" -gt 0 ]; then
    echo ""
    echo "=== DIAGNOSTIC INFO ==="
    echo "Warning: Detected $TOTAL_CALLS I/O syscalls but 0 bytes transferred."
    echo "This usually means the perf output format is not recognized."
    echo ""
    echo "Expected format variations:"
    echo "  Format 1: syscalls:sys_enter_read: ... count: 0x1234"
    echo "  Format 2: syscalls:sys_enter_read: ... count: 4660"
    echo "  Format 3: syscalls:sys_enter_read: ... count=0x1234"
    echo ""
    echo "Sample lines from your file:"
    grep -m3 -E 'sys_enter_(read|write|pread64|pwrite64):' "$SCRIPT_FILE" 2>/dev/null | head -3 || echo "  (no syscall lines found)"
    echo ""
    echo "Checking for size fields in syscall lines:"
    # Note: Use tr to strip any whitespace/newlines and ensure clean numeric output
    LINES_WITH_COUNT=$(grep -E 'sys_enter_(read|write|pread64|pwrite64):' "$SCRIPT_FILE" 2>/dev/null | grep -c 'count' 2>/dev/null | tr -d '\n\r ' || echo "0")
    LINES_WITH_LEN=$(grep -E 'sys_enter_(read|write|pread64|pwrite64):' "$SCRIPT_FILE" 2>/dev/null | grep -c 'len' 2>/dev/null | tr -d '\n\r ' || echo "0")
    LINES_WITH_NBYTE=$(grep -E 'sys_enter_(read|write|pread64|pwrite64):' "$SCRIPT_FILE" 2>/dev/null | grep -c 'nbyte' 2>/dev/null | tr -d '\n\r ' || echo "0")
    # Ensure numeric values (default to 0 if empty)
    LINES_WITH_COUNT=${LINES_WITH_COUNT:-0}
    LINES_WITH_LEN=${LINES_WITH_LEN:-0}
    LINES_WITH_NBYTE=${LINES_WITH_NBYTE:-0}
    echo "  Lines containing 'count': $LINES_WITH_COUNT out of $TOTAL_CALLS"
    echo "  Lines containing 'len': $LINES_WITH_LEN out of $TOTAL_CALLS"
    echo "  Lines containing 'nbyte': $LINES_WITH_NBYTE out of $TOTAL_CALLS"
    
    TOTAL_SIZE_FIELDS=$((LINES_WITH_COUNT + LINES_WITH_LEN + LINES_WITH_NBYTE))
    if [ "$TOTAL_SIZE_FIELDS" -eq 0 ]; then
        echo ""
        echo "No size field (count/len/nbyte) found in syscall events."
        echo "This can happen when:"
        echo "  1. Using an older perf version that doesn't include syscall arguments"
        echo "  2. The kernel doesn't expose syscall argument tracing"
        echo "  3. Different perf output format on this Linux distribution"
        echo ""
        echo "Try checking the syscall tracepoint format:"
        echo "  cat /sys/kernel/debug/tracing/events/syscalls/sys_enter_read/format"
        echo ""
        echo "You may need to use 'perf script -F' with specific fields."
    else
        echo ""
        echo "Size fields ARE present but values couldn't be extracted."
        echo "The parsing regex may need adjustment for your perf output format."
        echo "Please share a sample syscall line for debugging."
    fi
fi

echo ""
echo "=== Analysis Complete ==="
