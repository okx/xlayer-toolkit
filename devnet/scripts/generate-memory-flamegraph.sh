#!/bin/bash

set -e

CONTAINER=${1}
INPUT_FILE=${2:-"all"}
PROFILE_TYPE=${3:-"jemalloc"}

if [ -z "$CONTAINER" ]; then
    echo "Usage: $0 <container_name> [input_file|all|latest|last:N|file1,file2,...] [profile_type]"
    echo ""
    echo "Arguments:"
    echo "  container_name  - Docker container name (e.g., op-reth-seq)"
    echo "  input_file      - One of:"
    echo "                    - all         : Merge all .heap files"
    echo "                    - latest      : Use only the latest .heap file"
    echo "                    - last:N      : Merge the last N .heap files (e.g., last:5)"
    echo "                    - file1,file2 : Comma-separated list of specific files"
    echo "                    - filename    : Single file (e.g., jeprof.1.0.m0.heap)"
    echo "  profile_type    - Type: jemalloc (default) or heaptrack"
    echo ""
    echo "Examples:"
    echo "  $0 op-reth-seq                                              # Merge all .heap files"
    echo "  $0 op-reth-seq all                                          # Merge all .heap files"
    echo "  $0 op-reth-seq latest                                       # Use latest .heap file"
    echo "  $0 op-reth-seq last:5                                       # Merge last 5 .heap files"
    echo "  $0 op-reth-seq jeprof.1.0.m0.heap                           # Single file"
    echo "  $0 op-reth-seq jeprof.1.0.m0.heap,jeprof.1.1.i0.heap        # Specific files"
    exit 1
fi

OUTPUT_DIR="./profiling/${CONTAINER}"

# Ensure output directory exists and is writable
mkdir -p "$OUTPUT_DIR" 2>/dev/null || true

# Handle special input file values
if [ "$INPUT_FILE" = "all" ]; then
    echo "=== Merging all heap files ==="
    HEAP_FILES=$(ls -t "$OUTPUT_DIR"/*.heap 2>/dev/null)
    if [ -z "$HEAP_FILES" ]; then
        echo "Error: No .heap files found in $OUTPUT_DIR"
        exit 1
    fi
    FILE_COUNT=$(echo "$HEAP_FILES" | wc -l)
    echo "Found $FILE_COUNT heap files to merge"
    MERGE_MODE=true
    INPUT_PATH="$OUTPUT_DIR/merged.heap"

elif [ "$INPUT_FILE" = "latest" ]; then
    INPUT_PATH=$(ls -t "$OUTPUT_DIR"/*.heap 2>/dev/null | head -1)
    if [ -z "$INPUT_PATH" ]; then
        echo "Error: No .heap files found in $OUTPUT_DIR"
        exit 1
    fi
    INPUT_FILE=$(basename "$INPUT_PATH")
    echo "Using latest heap file: $INPUT_FILE"
    MERGE_MODE=false

elif [[ "$INPUT_FILE" =~ ^last:([0-9]+)$ ]]; then
    # last:N format - get the last N heap files
    N="${BASH_REMATCH[1]}"
    echo "=== Merging last $N heap files ==="
    HEAP_FILES=$(ls -t "$OUTPUT_DIR"/*.heap 2>/dev/null | head -"$N")
    if [ -z "$HEAP_FILES" ]; then
        echo "Error: No .heap files found in $OUTPUT_DIR"
        exit 1
    fi
    FILE_COUNT=$(echo "$HEAP_FILES" | wc -l)
    echo "Found $FILE_COUNT heap files to merge:"
    echo "$HEAP_FILES" | while read f; do echo "  - $(basename "$f")"; done
    MERGE_MODE=true
    INPUT_PATH="$OUTPUT_DIR/merged.heap"

elif [[ "$INPUT_FILE" == *","* ]]; then
    # Comma-separated list of files
    echo "=== Merging specified heap files ==="
    HEAP_FILES=""
    IFS=',' read -ra FILES <<< "$INPUT_FILE"
    for file in "${FILES[@]}"; do
        file_path="$OUTPUT_DIR/$file"
        if [ ! -f "$file_path" ]; then
            echo "Error: File not found: $file_path"
            exit 1
        fi
        HEAP_FILES="$HEAP_FILES"$'\n'"$file_path"
    done
    HEAP_FILES=$(echo "$HEAP_FILES" | sed '/^$/d')  # Remove empty lines
    FILE_COUNT=$(echo "$HEAP_FILES" | wc -l)
    echo "Merging $FILE_COUNT specified files:"
    echo "$HEAP_FILES" | while read f; do echo "  - $(basename "$f")"; done
    MERGE_MODE=true
    INPUT_PATH="$OUTPUT_DIR/merged.heap"

else
    # Single file
    INPUT_PATH="${OUTPUT_DIR}/${INPUT_FILE}"
    MERGE_MODE=false
    if [ ! -f "$INPUT_PATH" ]; then
        echo "Error: Input file not found: $INPUT_PATH"
        echo ""
        echo "Available .heap files in $OUTPUT_DIR:"
        ls -lht "$OUTPUT_DIR"/*.heap 2>/dev/null | head -10 || echo "No .heap files found"
        exit 1
    fi
fi

echo "=== Generating Memory Flamegraph ==="
echo "Container: $CONTAINER"
echo "Input: $INPUT_PATH"
echo "Type: $PROFILE_TYPE"
echo ""

# Clone FlameGraph tools if not present
FLAMEGRAPH_DIR="./profiling/FlameGraph"
if [ ! -d "$FLAMEGRAPH_DIR" ]; then
    echo "[1/4] Downloading FlameGraph tools..."
    git clone --depth 1 https://github.com/brendangregg/FlameGraph.git "$FLAMEGRAPH_DIR"
else
    echo "[1/4] FlameGraph tools already present"
fi

# Set output file names
if [ "$MERGE_MODE" = true ]; then
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    BASENAME="merged-${TIMESTAMP}"
else
    BASENAME=$(basename "$INPUT_FILE" | sed -e 's/\.heap$//' -e 's/\.data\.gz$//' -e 's/\.folded$//')
fi
FOLDED_FILE="${OUTPUT_DIR}/${BASENAME}.folded"
SVG_FILE="${OUTPUT_DIR}/${BASENAME}-allocations-demangled.svg"

case "$PROFILE_TYPE" in
    jemalloc)
        # Get the process PID
        RETH_PID=$(docker exec "$CONTAINER" sh -c 'pgrep -f "op-reth node" | head -1' 2>/dev/null || echo "1")

        if [ "$MERGE_MODE" = true ]; then
            echo "[2/4] Merging and parsing all heap files..."

            # Copy all heap files to container and merge allocations
            for heap_file in $HEAP_FILES; do
                filename=$(basename "$heap_file")
                if ! docker exec "$CONTAINER" test -f "/profiling/$filename" 2>/dev/null; then
                    docker cp "$heap_file" "$CONTAINER:/profiling/$filename"
                fi
            done

            # Create merged heap data by extracting allocations from all files
            docker exec "$CONTAINER" bash -c '
                > /profiling/merged_allocs.txt
                for f in /profiling/*.heap; do
                    [ -f "$f" ] || continue
                    awk "/^@/{stack=\$0; getline; if(\$0 ~ /t\*:/) {split(\$0,a,\" \"); bytes=a[3]; gsub(/[^0-9]/,\"\",bytes); if(bytes+0>0) print bytes, stack}}" "$f" >> /profiling/merged_allocs.txt
                done
                # Sort by size and take top 200 unique stacks
                sort -rn /profiling/merged_allocs.txt | head -200 > /profiling/top_allocs.txt
            '
            HEAP_FILE_IN_CONTAINER="/profiling/top_allocs.txt"
            USE_MERGED=true
        else
            echo "[2/4] Parsing jemalloc heap file..."

            # Copy heap file to container if analyzing local file
            HEAP_FILE_IN_CONTAINER="/profiling/$(basename "$INPUT_FILE")"

            # Check if file exists in container, if not copy it
            if ! docker exec "$CONTAINER" test -f "$HEAP_FILE_IN_CONTAINER" 2>/dev/null; then
                echo "  Copying heap file to container..."
                docker cp "$INPUT_PATH" "$CONTAINER:$HEAP_FILE_IN_CONTAINER"
            fi
            USE_MERGED=false
        fi

        echo "[3/4] Resolving symbols and generating folded stacks..."
        echo "  (This may take a few minutes for large binaries...)"

        # Build symbol cache using nm (much faster than addr2line for lookups)
        echo "  Building symbol table..."

        docker exec "$CONTAINER" bash -c '
HEAP_FILE="'"$HEAP_FILE_IN_CONTAINER"'"
PID="'"$RETH_PID"'"
USE_MERGED="'"$USE_MERGED"'"

# Get base address
BASE_HEX=$(cat /proc/$PID/maps 2>/dev/null | grep "op-reth" | head -1 | cut -d"-" -f1 || echo "0")
if [ "$BASE_HEX" = "0" ] || [ -z "$BASE_HEX" ]; then
    # Fallback: try to get it from any running op-reth
    BASE_HEX=$(cat /proc/1/maps 2>/dev/null | grep "op-reth" | head -1 | cut -d"-" -f1 || echo "0")
fi
BASE_DEC=$((0x$BASE_HEX))

echo "  Base address: 0x$BASE_HEX"

# Build symbol table from nm with DECIMAL addresses (for proper numeric comparison)
echo "  Extracting symbols from binary (this may take a moment)..."
# Use perl for fast hex-to-decimal conversion if available, otherwise use bash
if command -v perl &> /dev/null; then
    nm -n /usr/local/bin/op-reth 2>/dev/null | grep -E "^[0-9a-f]+ [TtWw]" | \
        perl -ne "if (/^([0-9a-f]+)\s+\S+\s+(\S+)/) { print hex(\$1), \" \$2\\n\"; }" > /tmp/symbols_dec.txt
else
    # Fallback to bash (slower but works)
    nm -n /usr/local/bin/op-reth 2>/dev/null | grep -E "^[0-9a-f]+ [TtWw]" | \
        while read addr type name; do echo "$((0x$addr)) $name"; done > /tmp/symbols_dec.txt
fi
SYMBOL_COUNT=$(wc -l < /tmp/symbols_dec.txt)
echo "  Found $SYMBOL_COUNT symbols"

echo "  Processing heap allocations..."

# Parse allocations - different format for merged vs single file
if [ "$USE_MERGED" = "true" ]; then
    # Merged file already has format: bytes @ addr1 addr2 ...
    INPUT_DATA=$(cat "$HEAP_FILE")
else
    # Single heap file needs awk parsing
    INPUT_DATA=$(awk "/^@/{stack=\$0; getline; if(\$0 ~ /t\*:/) {split(\$0,a,\" \"); bytes=a[3]; gsub(/[^0-9]/,\"\",bytes); if(bytes+0>0) print bytes, stack}}" "$HEAP_FILE" | sort -rn | head -100)
fi

# Process allocations
echo "$INPUT_DATA" | while read bytes stack; do
    [ -z "$bytes" ] && continue

    # Get addresses (reversed for flamegraph - bottom to top)
    ADDRS=$(echo "$stack" | tr " " "\n" | grep "0x" | tac)

    FUNCS=""
    for addr in $ADDRS; do
        ADDR_DEC=$((addr))
        REL_DEC=$((ADDR_DEC - BASE_DEC))

        # Lookup symbol using decimal comparison
        FUNC=$(awk -v target="$REL_DEC" "{
            if (\$1 <= target) {
                sym = \$2
            }
        } END { print (sym ? sym : \"unknown\") }" /tmp/symbols_dec.txt)

        # Clean up function name (remove Rust hash suffix and generics)
        FUNC=$(echo "$FUNC" | sed -e "s/::h[0-9a-f]\{16\}$//" -e "s/\.llvm\.[0-9]*$//" | head -c 100)

        if [ -n "$FUNC" ] && [ "$FUNC" != "unknown" ]; then
            if [ -n "$FUNCS" ]; then
                FUNCS="$FUNCS;$FUNC"
            else
                FUNCS="$FUNC"
            fi
        fi
    done

    if [ -n "$FUNCS" ]; then
        echo "$FUNCS $bytes"
    fi
done > /profiling/jemalloc.folded

rm -f /tmp/symbols_dec.txt
echo "  Done processing allocations"
'

        # Copy folded file out
        docker cp "$CONTAINER:/profiling/jemalloc.folded" "$FOLDED_FILE" 2>/dev/null || {
            echo "Error: Failed to generate folded stacks"
            exit 1
        }

        # Check if we got data
        if [ ! -s "$FOLDED_FILE" ]; then
            echo ""
            echo "Warning: No allocation data was extracted"
            echo "The heap file might be empty or in an unexpected format"
            exit 1
        fi

        STACK_COUNT=$(wc -l < "$FOLDED_FILE")
        echo "  Generated $STACK_COUNT stack traces"
        ;;

    heaptrack)
        echo "[2/4] Converting heaptrack data to folded format..."

        if docker exec "$CONTAINER" which heaptrack_print > /dev/null 2>&1; then
            docker exec "$CONTAINER" sh -c "
                heaptrack_print --print-peaks 1 '/profiling/${INPUT_FILE}' 2>/dev/null | \
                awk '/^[0-9]/ {
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
            " 2>/dev/null

            docker cp "$CONTAINER:/profiling/heaptrack.folded" "$FOLDED_FILE" 2>/dev/null || {
                echo "Warning: Could not generate folded format from heaptrack"
                exit 1
            }
        else
            echo "Error: heaptrack_print not available in container"
            exit 1
        fi

        echo "[3/4] Folded stacks ready"
        ;;

    *)
        echo "Error: Unknown profile type: $PROFILE_TYPE"
        echo "Supported types: jemalloc, heaptrack"
        exit 1
        ;;
esac

# Check if we have valid folded data
if [ ! -f "$FOLDED_FILE" ] || [ ! -s "$FOLDED_FILE" ]; then
    echo ""
    echo "Error: No folded stack data generated"
    exit 1
fi

# Demangle Rust/C++ symbols for readable function names
echo "[4/5] Demangling Rust symbols..."
DEMANGLED_FILE="${FOLDED_FILE%.folded}.demangled.folded"

if command -v rustfilt &> /dev/null; then
    # rustfilt is preferred for Rust symbols
    rustfilt < "$FOLDED_FILE" > "$DEMANGLED_FILE.tmp"
    echo "  Used rustfilt for demangling"
elif command -v ~/.cargo/bin/rustfilt &> /dev/null; then
    # Try cargo bin path
    ~/.cargo/bin/rustfilt < "$FOLDED_FILE" > "$DEMANGLED_FILE.tmp"
    echo "  Used rustfilt for demangling"
elif command -v c++filt &> /dev/null; then
    # c++filt works for most Rust symbols too
    c++filt < "$FOLDED_FILE" > "$DEMANGLED_FILE.tmp"
    echo "  Used c++filt for demangling"
else
    # No demangling available, use original
    cp "$FOLDED_FILE" "$DEMANGLED_FILE.tmp"
    echo "  Warning: No demangling tool available (install rustfilt: cargo install rustfilt)"
fi

# Clean up any remaining Rust mangling artifacts
echo "  Cleaning up symbol names..."
sed -e 's/\$LT\$/</g' \
    -e 's/\$GT\$/>/g' \
    -e 's/\$u20\$/ /g' \
    -e 's/\$u7b\$/{/g' \
    -e 's/\$u7d\$/}/g' \
    -e 's/\$C\$/,/g' \
    -e 's/\.\./\:\:/g' \
    -e 's/_ZN[0-9]*//g' \
    -e 's/17h[0-9a-f]\{16\}//g' \
    "$DEMANGLED_FILE.tmp" > "$DEMANGLED_FILE"
rm -f "$DEMANGLED_FILE.tmp"

# Use demangled file for flamegraph
FOLDED_FILE="$DEMANGLED_FILE"

# Generate flamegraph SVG
echo "[5/5] Generating interactive flamegraph..."

TITLE="Memory Allocations - $CONTAINER - $BASENAME"

"$FLAMEGRAPH_DIR/flamegraph.pl" \
    --title "$TITLE" \
    --width 1800 \
    --fontsize 12 \
    --colors "mem" \
    --countname "bytes" \
    "$FOLDED_FILE" > "$SVG_FILE"

SVG_SIZE=$(du -h "$SVG_FILE" | cut -f1)
TOTAL_BYTES=$(awk '{sum += $NF} END {print sum}' "$FOLDED_FILE")

# Format total bytes
if [ "$TOTAL_BYTES" -ge 1073741824 ]; then
    TOTAL_FMT="$((TOTAL_BYTES / 1073741824))GB"
elif [ "$TOTAL_BYTES" -ge 1048576 ]; then
    TOTAL_FMT="$((TOTAL_BYTES / 1048576))MB"
elif [ "$TOTAL_BYTES" -ge 1024 ]; then
    TOTAL_FMT="$((TOTAL_BYTES / 1024))KB"
else
    TOTAL_FMT="${TOTAL_BYTES}B"
fi

echo ""
echo "=== Flamegraph Generated ==="
echo ""
echo "Output: $SVG_FILE ($SVG_SIZE)"
echo "Total allocations tracked: $TOTAL_FMT ($TOTAL_BYTES bytes)"
echo ""
echo "To view the flamegraph:"
echo "  open $SVG_FILE"
echo ""
echo "Flamegraph tips:"
echo "  - Click on any box to zoom in"
echo "  - Click 'Reset Zoom' to zoom back out"
echo "  - Hover over boxes to see function names and allocation sizes"
echo "  - Search (Ctrl+F) to highlight specific functions"
echo "  - Wider boxes = more memory allocated in that call path"
echo ""

# Show top allocators
echo "Top allocating functions:"
echo "----------------------------------------"
awk -F';' '{print $NF}' "$FOLDED_FILE" | sort | uniq -c | sort -rn | head -10 | while read count func; do
    echo "  $func"
done
echo "----------------------------------------"
