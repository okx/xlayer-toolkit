#!/bin/bash

set -e

source .env

# Configuration
RBUILDER_SOURCE_DIR=${OP_RBUILDER_LOCAL_DIRECTORY:-"../../op-rbuilder"}
IMAGE_TAG=${OP_RBUILDER_IMAGE_TAG:-"op-rbuilder:profiling"}
RBUILDER_BIN=${OP_RBUILDER_BIN:-"op-rbuilder"}
# Add jemalloc features to existing features
FEATURES=${OP_RBUILDER_FEATURES:-"jemalloc,jemalloc-prof"}

echo "=== Building op-rbuilder with Profiling Support ==="
echo "Source: $RBUILDER_SOURCE_DIR"
echo "Image: $IMAGE_TAG"
echo "Binary: $RBUILDER_BIN"
echo "Features: $FEATURES"
echo ""

# Check if source directory exists
if [ ! -d "$RBUILDER_SOURCE_DIR" ]; then
    echo "Error: op-rbuilder source directory not found: $RBUILDER_SOURCE_DIR"
    echo "Please set OP_RBUILDER_LOCAL_DIRECTORY to your op-rbuilder source path"
    echo "Example: export OP_RBUILDER_LOCAL_DIRECTORY=~/code/op-rbuilder"
    exit 1
fi

# Get absolute path
RBUILDER_SOURCE_DIR=$(cd "$RBUILDER_SOURCE_DIR" && pwd)

echo "[1/2] Creating Dockerfile with profiling support..."
cd "$RBUILDER_SOURCE_DIR"

# Create a temporary Dockerfile based on op-rbuilder's actual structure
cat > Dockerfile.profiling.tmp <<'EOF'
#
# Base container (with sccache and cargo-chef)
#
ARG FEATURES
ARG RBUILDER_BIN="op-rbuilder"

FROM rust:1.88 AS base
ARG TARGETPLATFORM

RUN apt-get update \
    && apt-get install -y clang libclang-dev libtss2-dev

RUN rustup component add clippy rustfmt

RUN set -eux; \
    case "$TARGETPLATFORM" in \
      "linux/amd64")  ARCH_TAG="x86_64-unknown-linux-musl" ;; \
      "linux/arm64")  ARCH_TAG="aarch64-unknown-linux-musl" ;; \
      *) \
        echo "Unsupported platform: $TARGETPLATFORM"; \
        exit 1 \
        ;; \
    esac; \
    wget -O /tmp/sccache.tar.gz \
      "https://github.com/mozilla/sccache/releases/download/v0.8.2/sccache-v0.8.2-${ARCH_TAG}.tar.gz"; \
    tar -xf /tmp/sccache.tar.gz -C /tmp; \
    mv /tmp/sccache-v0.8.2-${ARCH_TAG}/sccache /usr/local/bin/sccache; \
    chmod +x /usr/local/bin/sccache; \
    rm -rf /tmp/sccache.tar.gz /tmp/sccache-v0.8.2-${ARCH_TAG}

RUN cargo install cargo-chef --version ^0.1

ENV CARGO_HOME=/usr/local/cargo
ENV RUSTC_WRAPPER=sccache
ENV SCCACHE_DIR=/sccache

#
# Planner container
#
FROM base AS planner
WORKDIR /app
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=$SCCACHE_DIR,sharing=locked \
    cargo chef prepare --recipe-path recipe.json

#
# Builder container with profiling support
#
FROM base AS builder
WORKDIR /app
COPY --from=planner /app/recipe.json recipe.json
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=$SCCACHE_DIR,sharing=locked \
    cargo chef cook --release --recipe-path recipe.json
COPY . .

#
# Build with profiling flags
#
FROM builder AS rbuilder-profiling
ARG RBUILDER_BIN
ARG FEATURES
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=$SCCACHE_DIR,sharing=locked \
    RUSTFLAGS="-C force-frame-pointers=yes -C target-cpu=native" \
    cargo build --release --features="$FEATURES" --package=${RBUILDER_BIN}

#
# Profiling runtime container (debian with profiling tools, not distroless)
#
FROM debian:bookworm-slim AS rbuilder-profiling-runtime
ARG RBUILDER_BIN

# Install runtime dependencies and profiling tools
# Note: Installing libtss2 runtime libraries (required by op-rbuilder)
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    libssl3 \
    procps \
    binutils \
    gdb \
    libtss2-esys-3.0.2-0 \
    libtss2-mu0 \
    libtss2-sys1 \
    libtss2-tcti-device0 \
    && rm -rf /var/lib/apt/lists/*

# Install perf from bookworm repos (supports newer kernels)
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
    linux-perf \
    && rm -rf /var/lib/apt/lists/*

# Install memory profiling tools
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
    heaptrack \
    valgrind \
    libjemalloc2 \
    libjemalloc-dev \
    google-perftools \
    libgoogle-perftools-dev \
    graphviz \
    rustfilt \
    && rm -rf /var/lib/apt/lists/*

# Create symlinks for jemalloc profiling tools
RUN ln -sf /usr/bin/google-pprof /usr/local/bin/jeprof || true

# The linux-perf package installs versioned binaries in /usr/lib/linux-tools/
# Find and symlink them to /usr/bin for easy access
RUN echo "Setting up perf binaries..." && \
    mkdir -p /usr/local/bin && \
    find /usr/lib -name "perf" -type f 2>/dev/null | while read perf_path; do \
        version=$(echo "$perf_path" | grep -oP '\d+\.\d+' | head -1); \
        if [ -n "$version" ]; then \
            echo "Found perf version $version at $perf_path"; \
            ln -sf "$perf_path" "/usr/local/bin/perf_$version"; \
        fi; \
    done && \
    newest_perf=$(find /usr/lib -name "perf" -type f 2>/dev/null | head -1); \
    if [ -n "$newest_perf" ]; then \
        ln -sf "$newest_perf" /usr/local/bin/perf; \
        echo "Created generic perf symlink to: $newest_perf"; \
    fi && \
    echo "Installed perf binaries:" && \
    ls -lh /usr/local/bin/perf* 2>/dev/null || echo "Warning: No perf binaries found"

# Copy op-rbuilder binary from builder stage
WORKDIR /app
COPY --from=rbuilder-profiling /app/target/release/${RBUILDER_BIN} /usr/local/bin/op-rbuilder

# Create directories for data and profiling output
RUN mkdir -p /datadir /profiling

# Expose ports (same as original)
EXPOSE 8545 8546 8547 30303 30303/udp

# Set working directory
WORKDIR /

# Default entrypoint
ENTRYPOINT ["/usr/local/bin/op-rbuilder"]
EOF

echo "[2/2] Building Docker image (this may take a while)..."
docker build --progress=plain \
    -f Dockerfile.profiling.tmp \
    --build-arg RBUILDER_BIN="$RBUILDER_BIN" \
    --build-arg FEATURES="$FEATURES" \
    --target rbuilder-profiling-runtime \
    -t "$IMAGE_TAG" .

# Cleanup
rm Dockerfile.profiling.tmp

echo ""
echo "=== Verifying image ==="
docker run --rm "$IMAGE_TAG" --version || echo "Note: Binary verification may fail if it requires specific runtime config"

echo ""
echo "=== Build Complete ==="
echo "Image: $IMAGE_TAG"
echo ""
echo "The image includes:"
echo "  - op-rbuilder built with profiling support (debug symbols + frame pointers)"
echo "  - Features enabled: $FEATURES"
echo "  - CPU profiling: perf tools for multiple kernel versions (5.10, 6.1, 6.10+)"
echo "  - Memory profiling: heaptrack, valgrind (massif), jemalloc profiling"
echo "  - binutils (for addr2line symbol resolution)"
echo "  - graphviz (for visualization)"
echo "  - rustfilt (for demangling Rust symbols)"
echo ""
echo "To use this image, update docker-compose.yml:"
echo "  op-rbuilder:"
echo "    image: $IMAGE_TAG"
echo "    # ... rest of config"
echo ""
echo "Or set in your .env file:"
echo "  OP_RBUILDER_IMAGE_TAG=$IMAGE_TAG"
echo ""
echo "Then restart the container:"
echo "  docker-compose up -d op-rbuilder"
echo ""
echo "Available profiling scripts:"
echo "  - CPU profiling:"
echo "    ./scripts/profile-reth-perf.sh op-rbuilder 60 \"op-rbuilder node\""
echo ""
echo "  - Memory profiling (jemalloc):"
echo "    ./scripts/profile-reth-jemalloc.sh op-rbuilder 60 \"op-rbuilder node\" \"op-rbuilder\""
echo ""
echo "Note: Make sure to:"
echo "  1. Add profiling volume mount in docker-compose.yml:"
echo "     - ./profiling/op-rbuilder:/profiling"
echo "  2. Enable jemalloc profiling in .env (for memory profiling):"
echo "     JEMALLOC_PROFILING=true"
echo "  3. Update entrypoint/op-rbuilder.sh to set _RJEM_MALLOC_CONF"

