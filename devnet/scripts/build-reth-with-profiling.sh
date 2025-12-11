#!/bin/bash

set -e

source .env

# Verify it's xlayer-reth
cd $OP_RETH_LOCAL_DIRECTORY
set +e
cargo tree -p xlayer-reth-node &>/dev/null
result=$?
set -e
cd - 

DOCKERFILE=${DOCKERFILE:=Dockerfile.profiling}
if [ "$result" -eq 0 ]; then
	  DOCKERFILE="Dockerfile-xlayer-reth.profiling"
fi

# Configuration
RETH_SOURCE_DIR=${OP_RETH_LOCAL_DIRECTORY:-"../../reth"}
IMAGE_TAG=${OP_RETH_IMAGE_TAG:-"op-reth:profiling"}

echo "=== Building op-reth with Profiling Support ==="
echo "Reth directory: $OP_RETH_LOCAL_DIRECTORY"
echo "Source: $RETH_SOURCE_DIR"
echo "Image: $IMAGE_TAG"
echo "Dockerfile: $DOCKERFILE"
echo ""

# Check if source directory exists
if [ ! -d "$RETH_SOURCE_DIR" ]; then
    echo "Error: Reth source directory not found: $RETH_SOURCE_DIR"
    echo "Please set OP_RETH_LOCAL_DIRECTORY to your reth source path"
    exit 1
fi

# Get absolute path
RETH_SOURCE_DIR=$(cd "$RETH_SOURCE_DIR" && pwd)

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DEVNET_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

echo "[1/2] Copying Dockerfile to reth directory..."
cd "$RETH_SOURCE_DIR"

# Copy the Dockerfile from the devnet directory
if [ ! -f "$DEVNET_DIR/dockerfile/$DOCKERFILE" ]; then
    echo "Error: Dockerfile.profiling not found at $DEVNET_DIR/dockerfile/$DOCKERFILE"
    exit 1
fi

# Copies to reth folder.
cp "$DEVNET_DIR/dockerfile/$DOCKERFILE" Dockerfile.profiling.tmp

echo "[2/2] Building Docker image (this may take a while)..."
docker build --progress=plain -f Dockerfile.profiling.tmp -t "$IMAGE_TAG" .

# Cleanup
rm Dockerfile.profiling.tmp

echo ""
echo "=== Verifying image ==="
docker run --rm "$IMAGE_TAG" op-reth --version

echo ""
echo "=== Build Complete ==="
echo "Image: $IMAGE_TAG"
echo ""
echo "The image includes:"
echo "  - op-reth built with profiling support (debug symbols + frame pointers)"
echo "  - CPU profiling: perf tools for multiple kernel versions (5.10, 6.1, 6.10+)"
echo "  - Memory profiling: heaptrack, valgrind (massif), jemalloc profiling"
echo "  - binutils (for addr2line symbol resolution)"
echo "  - graphviz (for visualization)"
echo ""
echo "Available profiling scripts:"
echo "  - ./scripts/profile-reth-perf.sh (CPU profiling)"
echo "  - ./scripts/profile-reth-offcpu.sh (Off-CPU profiling)"
echo "  - ./scripts/profile-reth-heaptrack.sh (Memory profiling - recommended)"
echo "  - ./scripts/profile-reth-jemalloc.sh (Jemalloc heap profiling)"
echo "  - ./scripts/profile-reth-massif.sh (Memory timeline profiling)"
echo ""
echo "Note: The profiling scripts will auto-detect and use the matching tools"
echo "      for your container's kernel version."
