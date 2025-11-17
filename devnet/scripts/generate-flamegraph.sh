#!/bin/bash

set -e

CONTAINER=${1:-op-reth-seq}
PERF_SCRIPT_FILE=${2}

if [ -z "$PERF_SCRIPT_FILE" ]; then
    echo "Usage: $0 <container_name> <perf_script_file>"
    echo ""
    echo "Available perf scripts for $CONTAINER:"
    echo ""
    ls -lht "./profiling/${CONTAINER}/"perf-*.script 2>/dev/null | head -10 || echo "No perf scripts found"
    echo ""
    echo "Example: $0 op-reth-seq perf-20251117-144128.script"
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

"$FLAMEGRAPH_DIR/stackcollapse-perf.pl" "$SCRIPT_PATH" > "$FOLDED_FILE"

# Generate flamegraph SVG
echo "[3/3] Generating interactive flamegraph..."
SVG_FILE="./profiling/${CONTAINER}/${BASENAME}.svg"

"$FLAMEGRAPH_DIR/flamegraph.pl" \
    --title "Reth CPU Profile - $BASENAME" \
    --width 1800 \
    --fontsize 14 \
    --fonttype "Verdana" \
    --colors java \
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
