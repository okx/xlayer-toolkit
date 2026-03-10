#!/bin/bash
set -e

N=${N:-1000}
MODE=${MODE:-execute}            # execute | prove
INLINE=${INLINE:-false}          # true | false
CMD=${1:-run}                    # build | build-guest | run | install-cli

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JOLT_REV="2e05fe883920054df2ee3a6df8f85c2caba77c99"
DOCKER_IMAGE="jolt-sha2-guest-builder"

case "$CMD" in
  install-cli)
    echo "Installing jolt CLI tool (rev: ${JOLT_REV:0:8})..."
    cargo +nightly install --git https://github.com/a16z/jolt --rev "$JOLT_REV" --force --bins jolt
    echo "Done. jolt CLI installed at: $(which jolt)"
    ;;
  build-guest)
    echo "Building guest ELFs in Docker (bypasses Santa)..."
    cd "$SCRIPT_DIR"
    docker build -t "$DOCKER_IMAGE" .
    # Copy compiled ELF binaries from Docker to host
    CONTAINER_ID=$(docker create "$DOCKER_IMAGE")

    # Inline ELF
    ELF_INLINE="target/jolt-guest/sha2-guest-sha2_chain_inline/riscv64imac-unknown-none-elf/release"
    mkdir -p "$SCRIPT_DIR/$ELF_INLINE"
    docker cp "$CONTAINER_ID:/src/$ELF_INLINE/sha2-guest" "$SCRIPT_DIR/$ELF_INLINE/"

    # Native ELF
    ELF_NATIVE="target/jolt-guest/sha2-guest-sha2_chain_native/riscv64imac-unknown-none-elf/release"
    mkdir -p "$SCRIPT_DIR/$ELF_NATIVE"
    docker cp "$CONTAINER_ID:/src/$ELF_NATIVE/sha2-guest" "$SCRIPT_DIR/$ELF_NATIVE/"

    docker rm "$CONTAINER_ID"
    echo "Guest ELFs copied."
    ;;
  build)
    cd "$SCRIPT_DIR"
    cargo +nightly build --release --bin sha2-bench
    ;;
  run)
    INLINE_FLAG=""
    if [ "$INLINE" = "true" ]; then
        INLINE_FLAG="--inline"
    fi
    RUST_LOG="${RUST_LOG:-info}" \
        "$SCRIPT_DIR/target/release/sha2-bench" \
        "--${MODE}" --n "$N" $INLINE_FLAG
    ;;
  *)
    echo "Usage: $0 [install-cli|build-guest|build|run]"
    echo "  install-cli  Install jolt CLI tool (required if not using Docker)"
    echo "  build-guest  Build guest ELFs in Docker (use this if Santa blocks local build)"
    echo "  build        Build the host binary natively"
    echo "  run          Run benchmark (MODE=execute|prove, N=<iters>, INLINE=true|false)"
    echo ""
    echo "Workflow (with Santa):"
    echo "  ./run.sh build-guest   # compile guests in Docker"
    echo "  ./run.sh build         # compile host natively"
    echo "  N=1000 MODE=prove INLINE=true ./run.sh run"
    echo ""
    echo "Workflow (without Santa):"
    echo "  ./run.sh install-cli   # install jolt CLI"
    echo "  ./run.sh build         # compile host"
    echo "  N=1000 MODE=prove INLINE=false ./run.sh run"
    exit 1
    ;;
esac
