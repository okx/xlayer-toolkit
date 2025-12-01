#!/bin/bash

set -e

CONTAINER=${1:-op-reth-seq}
PERF_SCRIPT_FILE=${2}
PROFILE_TYPE=${3:-cpu}  # cpu, offcpu, memory

if [ -z "$PERF_SCRIPT_FILE" ]; then
    echo "Usage: $0 <container_name> <perf_script_file> [profile_type]"
    echo ""
    echo "Arguments:"
    echo "  container_name  - Docker container name (default: op-reth-seq)"
    echo "  perf_script_file - Perf script filename (e.g., perf-20251117-144128.script)"
    echo "  profile_type    - Type of profile: cpu, offcpu, memory (default: cpu)"
    echo ""
    echo "Available perf scripts for $CONTAINER:"
    echo ""
    ls -lht "./profiling/${CONTAINER}/"perf-*.script 2>/dev/null | head -10 || echo "No perf scripts found"
    echo ""
    echo "Example: $0 op-reth-seq perf-20251117-144128.script cpu"
    echo "Example: $0 op-reth-seq perf-offcpu-20251117-144128.script offcpu"
    exit 1
fi

SCRIPT_PATH="./profiling/${CONTAINER}/${PERF_SCRIPT_FILE}"

if [ ! -f "$SCRIPT_PATH" ]; then
    echo "Error: Perf script file not found: $SCRIPT_PATH"
    echo ""
    echo "Available perf scripts:"
    ls -lht "./profiling/${CONTAINER}/"perf-*.script 2>/dev/null | head -10 || echo "No perf scripts found"
    exit 1
fi

echo "=== Generating Flamegraph from Perf Data ==="
echo "Input: $SCRIPT_PATH"
echo ""

# Clone FlameGraph tools if not present
FLAMEGRAPH_DIR="./profiling/FlameGraph"
if [ ! -d "$FLAMEGRAPH_DIR" ]; then
    echo "[1/3] Downloading FlameGraph tools..."
    git clone https://github.com/brendangregg/FlameGraph.git "$FLAMEGRAPH_DIR"
else
    echo "[1/3] FlameGraph tools already present"
fi

# Generate folded stacks from perf script
echo "[2/3] Processing perf script data..."
BASENAME=$(basename "$PERF_SCRIPT_FILE" .script)
FOLDED_FILE="./profiling/${CONTAINER}/${BASENAME}.folded"

# Add kernel/user delimiter for off-CPU profiles
if [ "$PROFILE_TYPE" = "offcpu" ]; then
    echo "    Adding kernel/user stack delimiters..."
    # stackcollapse-perf.pl with kernel/user annotation
    # Insert "--" delimiter between kernel and user stacks
    "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" "$SCRIPT_PATH" | \
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
                # Kernel functions typically include: __schedule, do_*, el0_*, futex_*, page_*, etc.
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
    "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" "$SCRIPT_PATH" > "$FOLDED_FILE"
fi

# Generate flamegraph SVG
echo "[3/3] Generating interactive flamegraph..."
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

echo ""
echo "Done!"
echo ""
echo "Flamegraph generated: $SVG_FILE ($SVG_SIZE)"
echo ""
echo "To view the flamegraph:"
echo "  1. Open in browser: open $SVG_FILE"
echo "  2. Or double-click the file to open in your default browser"
echo ""
echo "The flamegraph is interactive:"
echo "  - Click on any box to zoom in"
echo "  - Click 'Reset Zoom' to zoom back out"
echo "  - Hover over boxes to see function names and percentages"
