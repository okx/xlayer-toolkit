#!/bin/bash

set -e

CONTAINER=${1}
INPUT_FILE=${2}
PROFILE_TYPE=${3:-"memory"}

if [ -z "$CONTAINER" ] || [ -z "$INPUT_FILE" ]; then
    echo "Usage: $0 <container_name> <input_file> [profile_type]"
    echo ""
    echo "Arguments:"
    echo "  container_name  - Docker container name (e.g., op-reth-seq)"
    echo "  input_file      - Input data file name (e.g., heaptrack-20241117.data.gz)"
    echo "  profile_type    - Type: heaptrack, jemalloc, or memory (default: memory)"
    echo ""
    echo "Example:"
    echo "  $0 op-reth-seq heaptrack-20241117.data.gz heaptrack"
    echo "  $0 op-reth-seq jemalloc-20241117.folded jemalloc"
    exit 1
fi

OUTPUT_DIR="./profiling/${CONTAINER}"
INPUT_PATH="${OUTPUT_DIR}/${INPUT_FILE}"

if [ ! -f "$INPUT_PATH" ] && [ ! -f "$INPUT_PATH" ]; then
    echo "Error: Input file not found: $INPUT_PATH"
    echo ""
    echo "Available files in $OUTPUT_DIR:"
    ls -lht "$OUTPUT_DIR" 2>/dev/null | head -10 || echo "No files found"
    exit 1
fi

echo "=== Generating Memory Flamegraph ==="
echo "Input: $INPUT_PATH"
echo "Type: $PROFILE_TYPE"
echo ""

# Clone FlameGraph tools if not present
FLAMEGRAPH_DIR="./profiling/FlameGraph"
if [ ! -d "$FLAMEGRAPH_DIR" ]; then
    echo "[1/3] Downloading FlameGraph tools..."
    git clone https://github.com/brendangregg/FlameGraph.git "$FLAMEGRAPH_DIR"
else
    echo "[1/3] FlameGraph tools already present"
fi

BASENAME=$(basename "$INPUT_FILE" | sed -e 's/\.data\.gz$//' -e 's/\.folded$//' -e 's/\.txt$//')
FOLDED_FILE="${OUTPUT_DIR}/${BASENAME}.folded"
SVG_FILE="${OUTPUT_DIR}/${BASENAME}-allocations.svg"

# Process based on profile type
case "$PROFILE_TYPE" in
    heaptrack)
        echo "[2/3] Converting heaptrack data to folded format..."

        if [ ! -f "$INPUT_PATH" ]; then
            echo "Error: Heaptrack data file not found: $INPUT_PATH"
            exit 1
        fi

        # Check if heaptrack_print is available in container
        if docker exec "$CONTAINER" which heaptrack_print > /dev/null 2>&1; then
            # Generate folded format from heaptrack data
            docker exec "$CONTAINER" sh -c "
                heaptrack_print --print-peaks 1 '$INPUT_FILE' 2>/dev/null | \
                awk '/^[0-9]/ {
                    # Parse heaptrack output and convert to folded format
                    # Format: count stack1;stack2;stack3
                    if (\$1 ~ /^[0-9]+$/) {
                        count = \$1
                        stack = \"\"
                        for (i=2; i<=NF; i++) {
                            if (stack != \"\") stack = stack \";\"
                            stack = stack \$i
                        }
                        if (stack != \"\") print stack \" \" count
                    }
                }' > /profiling/heaptrack.folded
            " 2>/dev/null || {
                # Fallback: use heaptrack_print text output and parse it
                echo "Using alternative heaptrack parsing..."
                docker cp "$CONTAINER:/profiling/${INPUT_FILE}" /tmp/heaptrack-temp.gz

                docker exec "$CONTAINER" sh -c "
                    heaptrack_print '/profiling/${INPUT_FILE}' > /profiling/heaptrack-temp.txt 2>/dev/null
                " || true

                docker exec "$CONTAINER" sh -c "
                    # Simple parser for heaptrack text output
                    awk '
                        /bytes in [0-9]+ allocations/ {
                            # Extract allocation info
                            match(\$0, /([0-9]+) bytes/, bytes)
                            match(\$0, /in ([0-9]+) allocations/, count)
                            if (bytes[1] != \"\") {
                                size = bytes[1]
                                getline  # Get function name
                                gsub(/^[ \t]+/, \"\")
                                print \$0 \" \" size
                            }
                        }
                    ' /profiling/heaptrack-temp.txt > /profiling/heaptrack.folded 2>/dev/null
                " || echo "# No heaptrack data" > "$FOLDED_FILE"
            }

            docker cp "$CONTAINER:/profiling/heaptrack.folded" "$FOLDED_FILE" 2>/dev/null || {
                echo "Warning: Could not generate folded format from heaptrack"
                echo "# Heaptrack parsing failed" > "$FOLDED_FILE"
            }

            docker exec "$CONTAINER" rm -f /profiling/heaptrack.folded /profiling/heaptrack-temp.txt 2>/dev/null || true
        else
            echo "Warning: heaptrack_print not available, cannot generate flamegraph"
            echo "The .data.gz file can be analyzed with heaptrack_gui if available locally"
            exit 0
        fi
        ;;

    jemalloc)
        echo "[2/3] Using jemalloc folded format..."

        if [ -f "$INPUT_PATH" ]; then
            # Input is already in folded format
            cp "$INPUT_PATH" "$FOLDED_FILE"
        else
            echo "Error: Jemalloc folded file not found: $INPUT_PATH"
            exit 1
        fi
        ;;

    *)
        echo "Error: Unknown profile type: $PROFILE_TYPE"
        echo "Supported types: heaptrack, jemalloc"
        exit 1
        ;;
esac

# Check if we have valid folded data
if [ ! -f "$FOLDED_FILE" ] || [ ! -s "$FOLDED_FILE" ]; then
    echo ""
    echo "⚠️  WARNING: No folded stack data generated"
    echo ""
    echo "Why this happens:"
    if [ "$PROFILE_TYPE" = "heaptrack" ]; then
        echo "  - Heaptrack data file is empty or contains no allocation data"
        echo "  - This often occurs when heaptrack cannot intercept jemalloc allocations"
        echo "  - Reth uses jemalloc, which heaptrack may not be able to profile"
        echo ""
        echo "💡 SOLUTION: Use jemalloc profiling instead:"
        echo "   ./scripts/profile-reth-jemalloc.sh $CONTAINER 60"
    else
        echo "  - Input file is empty or invalid"
        echo "  - No stack trace data was captured"
    fi
    echo ""
    echo "Flamegraph cannot be created without data."
    exit 0
fi

# Generate flamegraph SVG
echo "[3/3] Generating interactive flamegraph..."

# Determine title based on type
case "$PROFILE_TYPE" in
    heaptrack)
        TITLE="Memory Allocations (Heaptrack) - $BASENAME"
        COLOR_SCHEME="mem"
        ;;
    jemalloc)
        TITLE="Memory Allocations (Jemalloc) - $BASENAME"
        COLOR_SCHEME="mem"
        ;;
    *)
        TITLE="Memory Allocations - $BASENAME"
        COLOR_SCHEME="mem"
        ;;
esac

"$FLAMEGRAPH_DIR/flamegraph.pl" \
    --title "$TITLE" \
    --width 1800 \
    --fontsize 14 \
    --fonttype "Verdana" \
    --colors "$COLOR_SCHEME" \
    --countname "bytes" \
    --inverted \
    "$FOLDED_FILE" > "$SVG_FILE"

SVG_SIZE=$(du -h "$SVG_FILE" | cut -f1)

echo ""
echo "Done!"
echo ""
echo "Memory flamegraph generated: $SVG_FILE ($SVG_SIZE)"
echo ""
echo "To view the flamegraph:"
echo "  1. Open in browser: open $SVG_FILE"
echo "  2. Or double-click the file to open in your default browser"
echo ""
echo "The flamegraph is interactive:"
echo "  - Click on any box to zoom in"
echo "  - Click 'Reset Zoom' to zoom back out"
echo "  - Hover over boxes to see function names and byte counts"
echo "  - Search (Ctrl+F) to highlight specific functions"
echo ""
