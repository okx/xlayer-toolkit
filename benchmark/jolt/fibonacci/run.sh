#!/bin/bash
set -e

N=${N:-20}
MODE=${MODE:-execute}            # execute | prove
CMD=${1:-run}                    # build | build-guest | run | install-cli

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JOLT_REV="2e05fe883920054df2ee3a6df8f85c2caba77c99"
DOCKER_IMAGE="jolt-fibonacci-guest-builder"

case "$CMD" in
  install-cli)
    echo "Installing jolt CLI tool (rev: ${JOLT_REV:0:8})..."
    cargo +nightly install --git https://github.com/a16z/jolt --rev "$JOLT_REV" --force --bins jolt
    echo "Done. jolt CLI installed at: $(which jolt)"
    ;;
  build-guest)
    echo "Building guest ELF in Docker (bypasses Santa)..."
    cd "$SCRIPT_DIR"
    docker build -t "$DOCKER_IMAGE" .
    # Copy only the compiled ELF binary from Docker to host
    CONTAINER_ID=$(docker create "$DOCKER_IMAGE")
    ELF_REL="target/jolt-guest/fibonacci-guest-fib/riscv64imac-unknown-none-elf/release"
    mkdir -p "$SCRIPT_DIR/$ELF_REL"
    docker cp "$CONTAINER_ID:/src/$ELF_REL/fibonacci-guest" \
        "$SCRIPT_DIR/$ELF_REL/"
    docker rm "$CONTAINER_ID"
    echo "Guest ELF copied to $ELF_REL/fibonacci-guest"
    ;;
  build)
    cd "$SCRIPT_DIR"
    cargo +nightly build --release --bin fibonacci-bench
    ;;
  run)
    RUST_LOG="${RUST_LOG:-info}" \
        "$SCRIPT_DIR/target/release/fibonacci-bench" \
        "--${MODE}" --n "$N"
    ;;
  *)
    echo "Usage: $0 [install-cli|build-guest|build|run]"
    echo "  install-cli  Install jolt CLI tool (required if not using Docker)"
    echo "  build-guest  Build guest ELF in Docker (use this if Santa blocks local build)"
    echo "  build        Build the host binary natively"
    echo "  run          Run benchmark (MODE=execute|prove, N=<n>)"
    echo ""
    echo "Workflow (with Santa):"
    echo "  ./run.sh build-guest   # compile guest in Docker"
    echo "  ./run.sh build         # compile host natively"
    echo "  N=20 MODE=prove ./run.sh run"
    echo ""
    echo "Workflow (without Santa):"
    echo "  ./run.sh install-cli   # install jolt CLI"
    echo "  ./run.sh build         # compile host"
    echo "  N=20 MODE=prove ./run.sh run  # guest compiles at runtime"
    exit 1
    ;;
esac
