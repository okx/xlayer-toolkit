#!/bin/bash

set -e

source .env

# Configuration
RETH_SOURCE_DIR=${OP_RETH_LOCAL_DIRECTORY:-"../../reth"}
IMAGE_TAG=${OP_RETH_IMAGE_TAG:-"op-reth:profiling"}

echo "=== Building op-reth with Profiling Support ==="
echo "Source: $RETH_SOURCE_DIR"
echo "Image: $IMAGE_TAG"
echo ""

# Check if source directory exists
if [ ! -d "$RETH_SOURCE_DIR" ]; then
    echo "Error: Reth source directory not found: $RETH_SOURCE_DIR"
    echo "Please set OP_RETH_LOCAL_DIRECTORY to your reth source path"
    exit 1
fi

# Get absolute path
RETH_SOURCE_DIR=$(cd "$RETH_SOURCE_DIR" && pwd)

echo "[1/2] Creating Dockerfile with multi-stage build..."
cd "$RETH_SOURCE_DIR"

# Create a temporary Dockerfile that builds everything in Docker
cat > Dockerfile.profiling.tmp <<'EOF'
# Multi-stage build: Build stage
FROM rust:1.88-bookworm AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    libclang-dev \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /build

# Copy source code
COPY . .

# Build op-reth with profiling support using the Makefile target
# RUN make profiling-op
RUN RUSTFLAGS="-C force-frame-pointers=yes -C target-cpu=native" cargo build --profile profiling --features jemalloc,asm-keccak --bin op-reth --manifest-path crates/optimism/bin/Cargo.toml

# Runtime stage
FROM debian:bookworm-slim

# Install runtime dependencies and profiling tools
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    libssl3 \
    procps \
    binutils \
    && rm -rf /var/lib/apt/lists/*

# Install perf from bookworm repos (supports newer kernels)
# Debian Bookworm has better kernel support (5.10, 6.1, 6.3+)
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
    linux-perf \
    && rm -rf /var/lib/apt/lists/*

# The linux-perf package installs versioned binaries in /usr/lib/linux-tools/
# Find and symlink them to /usr/bin for easy access
RUN echo "Setting up perf binaries..." && \
    mkdir -p /usr/local/bin && \
    # Find all installed perf binaries
    find /usr/lib -name "perf" -type f 2>/dev/null | while read perf_path; do \
        version=$(echo "$perf_path" | grep -oP '\d+\.\d+' | head -1); \
        if [ -n "$version" ]; then \
            echo "Found perf version $version at $perf_path"; \
            ln -sf "$perf_path" "/usr/local/bin/perf_$version"; \
        fi; \
    done && \
    # Create a generic perf symlink to the newest version
    newest_perf=$(find /usr/lib -name "perf" -type f 2>/dev/null | head -1); \
    if [ -n "$newest_perf" ]; then \
        ln -sf "$newest_perf" /usr/local/bin/perf; \
        echo "Created generic perf symlink to: $newest_perf"; \
    fi && \
    echo "" && \
    echo "Installed perf binaries:" && \
    ls -lh /usr/local/bin/perf* 2>/dev/null || echo "Warning: No perf binaries found"

# Copy op-reth binary from builder stage
COPY --from=builder /build/target/profiling/op-reth /usr/local/bin/op-reth

# Create directories for data and profiling output
RUN mkdir -p /datadir /profiling

# Expose ports
EXPOSE 8545 8546 8547 30303 30303/udp

# Set working directory
WORKDIR /

# Default command (will be overridden by entrypoint script)
CMD ["/usr/local/bin/op-reth", "--help"]
EOF

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
echo "  - perf tools for multiple kernel versions (5.10, 6.1, 6.10+)"
echo "  - binutils (for addr2line symbol resolution)"
echo ""
echo "Note: The profiling script will auto-detect and use the matching perf version"
echo "      for your container's kernel version."
