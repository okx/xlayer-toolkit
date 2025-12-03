#!/bin/bash

set -e

CONTAINER=${1:-op-reth-seq}
PERF_FILE=${2}
PROFILE_TYPE=${3:-cpu}  # cpu, offcpu, memory
VERBOSE=${VERBOSE:-false}  # Set VERBOSE=true for detailed output

if [ -z "$PERF_FILE" ]; then
    echo "Usage: $0 <container_name> <perf_file> [profile_type]"
    echo ""
    echo "Arguments:"
    echo "  container_name  - Docker container name (default: op-reth-seq)"
    echo "  perf_file       - Perf data filename (e.g., perf-20251117-144128.data)"
    echo "  profile_type    - Type of profile: cpu, offcpu, memory (default: cpu)"
    echo ""
    echo "Available perf data files for $CONTAINER:"
    echo ""
    ls -lht "./profiling/${CONTAINER}/"perf-*.data 2>/dev/null | head -10 || echo "No perf data files found"
    echo ""
    echo "Example: $0 op-reth-seq perf-20251117-144128.data cpu"
    echo "Example: $0 op-reth-seq perf-offcpu-20251117-144128.data offcpu"
    exit 1
fi

FILE_PATH="./profiling/${CONTAINER}/${PERF_FILE}"

if [ ! -f "$FILE_PATH" ]; then
    echo "Error: Perf data file not found: $FILE_PATH"
    echo ""
    echo "Available perf data files:"
    ls -lht "./profiling/${CONTAINER}/"perf-*.data 2>/dev/null | head -10 || echo "No perf data files found"
    exit 1
fi

# Detect file type
FILE_EXT="${PERF_FILE##*.}"

if [ "$FILE_EXT" != "data" ]; then
    echo "Error: This script only works with .data files"
    echo "Got: $PERF_FILE (.$FILE_EXT)"
    echo ""
    echo "If you have a .script file, use stackcollapse-perf.pl directly:"
    echo "  ./profiling/FlameGraph/stackcollapse-perf.pl $FILE_PATH | ./profiling/FlameGraph/flamegraph.pl > output.svg"
    exit 1
fi

# Helper function for verbose output
log_verbose() {
    if [ "$VERBOSE" = "true" ]; then
        echo "$@"
    fi
}

log_verbose "=== Generating Flamegraph from Perf Data ==="
log_verbose "Input: $FILE_PATH"
log_verbose ""

# Clone FlameGraph tools if not present
FLAMEGRAPH_DIR="./profiling/FlameGraph"
if [ ! -d "$FLAMEGRAPH_DIR" ]; then
    log_verbose "[1/3] Downloading FlameGraph tools..."
    git clone https://github.com/brendangregg/FlameGraph.git "$FLAMEGRAPH_DIR" >/dev/null 2>&1
else
    log_verbose "[1/3] FlameGraph tools already present"
fi

# Find perf binary in container
log_verbose "[2/3] Converting .data to folded stacks (streaming, no intermediate .script file)..."
PERF_BIN=$(docker exec "$CONTAINER" sh -c 'command -v perf 2>/dev/null || find /usr/local/bin /usr/bin -name "perf*" -type f -o -type l 2>/dev/null | grep -E "perf" | head -1 || echo ""')

if [ -z "$PERF_BIN" ]; then
    echo "Error: No perf binary found in container $CONTAINER"
    exit 1
fi

log_verbose "   Using perf binary: $PERF_BIN"

# Copy .data file to container
docker cp "$FILE_PATH" "$CONTAINER:/profiling/temp-perf.data" 2>/dev/null

# Stream perf script output directly through stackcollapse
BASENAME=$(basename "$PERF_FILE" .data)
FOLDED_FILE="./profiling/${CONTAINER}/${BASENAME}.folded"

# Add kernel/user delimiter for off-CPU profiles
if [ "$PROFILE_TYPE" = "offcpu" ]; then
    log_verbose "   Processing with kernel/user stack delimiters..."

    # Stream: perf script -> stackcollapse -> add delimiters -> folded file
    docker exec "$CONTAINER" sh -c "
        cd /profiling && \
        $PERF_BIN script -f -i temp-perf.data
    " 2>/dev/null | "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" | \
        awk -F';' '{
            # Last field is the count
            count_idx = NF;
            count = $count_idx;

            # Process stack frames (all but the last field which is count)
            new_stack = "";
            prev_was_kernel = 0;

            for (i = 1; i < count_idx; i++) {
                frame = $i;

                # Detect kernel frames by common kernel function patterns
                is_kernel = (frame ~ /__schedule|^schedule$|^do_|^el0_|^el0t_|futex_wait|futex_wake|page_fault|^handle_|invoke_syscall|^__arm64_|filemap_|read_pages|io_schedule|ksys_|vfs_|^__handle_|^__do_|^__futex|^__fuse|request_wait_answer|folio_wait|page_cache|page_touch|^__el0_|^__kernel_|^__close|^__GI_|fuse_|fakeowner_|lookup_|^filp_/);

                # Skip empty frames
                if (frame == "") continue;

                # Insert delimiter when transitioning from kernel to user
                if (prev_was_kernel && !is_kernel && new_stack != "") {
                    if (new_stack != "") new_stack = new_stack ";";
                    new_stack = new_stack "---";
                }

                if (new_stack != "") {
                    new_stack = new_stack ";";
                }
                new_stack = new_stack frame;
                prev_was_kernel = is_kernel;
            }

            print new_stack " " count;
        }' > "$FOLDED_FILE"
else
    log_verbose "   Processing stacks..."

    # Stream: perf script -> stackcollapse -> folded file
    docker exec "$CONTAINER" sh -c "
        cd /profiling && \
        $PERF_BIN script -f -i temp-perf.data
    " 2>/dev/null | "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" > "$FOLDED_FILE"
fi

# Check if we got any data
if [ ! -s "$FOLDED_FILE" ]; then
    echo ""
    echo "ERROR: No stack data generated"
    echo ""
    echo "Possible reasons:"
    echo "  1. The .data file has no samples (system was idle during profiling)"
    echo "  2. The events captured had no stack traces"
    echo "  3. Perf version mismatch"
    echo ""
    echo "Try profiling for longer or during higher load:"
    echo "  ./scripts/profile-reth-offcpu.sh $CONTAINER 60"
    
    # Clean up
    docker exec "$CONTAINER" sh -c 'rm -f /profiling/temp-perf.data' 2>/dev/null || true
    rm -f "$FOLDED_FILE"
    exit 1
fi

# Clean up temp files in container
docker exec "$CONTAINER" sh -c 'rm -f /profiling/temp-perf.data' 2>/dev/null || true

FOLDED_SIZE=$(du -h "$FOLDED_FILE" | cut -f1)
log_verbose "   Generated folded stacks: $FOLDED_SIZE"

# Generate flamegraph SVG
log_verbose "[3/3] Generating interactive flamegraph..."
SVG_FILE="./profiling/${CONTAINER}/${BASENAME}.svg"

# Set flamegraph options based on profile type
if [ "$PROFILE_TYPE" = "offcpu" ]; then
    TITLE="Reth Off-CPU Time - $BASENAME"
    COLOR_SCHEME="io"
    COUNTNAME="off-cpu time"
elif [ "$PROFILE_TYPE" = "memory" ]; then
    TITLE="Reth Memory Profile - $BASENAME"
    COLOR_SCHEME="mem"
    COUNTNAME="bytes"
else
    TITLE="Reth CPU Profile - $BASENAME"
    COLOR_SCHEME="hot"
    COUNTNAME="samples"
fi

"$FLAMEGRAPH_DIR/flamegraph.pl" \
    --title "$TITLE" \
    --width 1800 \
    --fontsize 14 \
    --fonttype "Verdana" \
    --colors "$COLOR_SCHEME" \
    --countname "$COUNTNAME" \
    --inverted \
    "$FOLDED_FILE" > "$SVG_FILE"

SVG_SIZE=$(du -h "$SVG_FILE" | cut -f1)

# Always show the final result
echo "Flamegraph: $SVG_FILE ($SVG_SIZE)"

# Verbose mode shows additional help
if [ "$VERBOSE" = "true" ]; then
    echo ""
    echo "To view the flamegraph:"
    echo "  1. Open in browser: open -a Google\ Chrome $SVG_FILE"
    echo "  2. Or double-click the file to open in your default browser"
    echo ""
fi
