#!/bin/bash
set -e

N=${N:-20}
MODE=${MODE:-execute}            # execute | prove
CMD=${1:-run}                    # build | build-guest | build-host | run | install-cli

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JOLT_REV="2e05fe883920054df2ee3a6df8f85c2caba77c99"

case "$CMD" in
  install-cli)
    echo "Installing jolt CLI tool (rev: ${JOLT_REV:0:8})..."
    cargo +nightly install --git https://github.com/a16z/jolt --rev "$JOLT_REV" --force --bins jolt
    echo "Done. jolt CLI installed at: $(which jolt)"
    ;;
  build-guest)
    cd "$SCRIPT_DIR"
    echo "Building guest ELF locally (requires jolt CLI + riscv64imac target)..."
    jolt build -p fibonacci-guest --backtrace off --stack-size 4096 --heap-size 32768 \
        -- --release --target-dir "$SCRIPT_DIR/target/jolt-guest/fibonacci-guest-fib" --features guest
    echo "Guest ELF built."
    ;;
  build-host)
    cd "$SCRIPT_DIR"
    cargo +nightly build --release --bin fibonacci-bench
    ;;
  build)
    # Build both guest ELF and host binary locally
    cd "$SCRIPT_DIR"
    echo "=== Building guest ELF ==="
    jolt build -p fibonacci-guest --backtrace off --stack-size 4096 --heap-size 32768 \
        -- --release --target-dir "$SCRIPT_DIR/target/jolt-guest/fibonacci-guest-fib" --features guest
    echo "=== Building host binary ==="
    cargo +nightly build --release --bin fibonacci-bench
    echo "Done."
    ;;
  run)
    RUST_LOG="${RUST_LOG:-info}" \
        "$SCRIPT_DIR/target/release/fibonacci-bench" \
        "--${MODE}" --n "$N"
    ;;
  *)
    echo "Usage: $0 [build|build-guest|build-host|run|install-cli]"
    echo "  install-cli  Install jolt CLI tool (one-time setup)"
    echo "  build        Build guest ELF + host binary locally"
    echo "  build-guest  Build guest ELF only"
    echo "  build-host   Build host binary only"
    echo "  run          Run benchmark (MODE=execute|prove, N=<n>)"
    echo ""
    echo "Setup:"
    echo "  rustup target add riscv64imac-unknown-none-elf"
    echo "  ./run.sh install-cli"
    echo "  ./run.sh build"
    echo "  N=20 MODE=prove ./run.sh run"
    exit 1
    ;;
esac
