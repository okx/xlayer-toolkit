#!/bin/bash
set -e

N=${N:-1000}
MODE=${MODE:-execute}            # execute | prove
INLINE=${INLINE:-false}          # true | false
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
    echo "Building guest ELFs locally (requires jolt CLI + riscv64imac target)..."
    jolt build -p sha2-guest --backtrace off --stack-size 4096 \
        -- --release --target-dir "$SCRIPT_DIR/target/jolt-guest" --features guest
    echo "Guest ELFs built."
    ;;
  build-host)
    cd "$SCRIPT_DIR"
    cargo +nightly build --release --bin sha2-bench
    ;;
  build)
    # Build both guest ELFs and host binary locally
    cd "$SCRIPT_DIR"
    echo "=== Building guest ELFs ==="
    jolt build -p sha2-guest --backtrace off --stack-size 4096 \
        -- --release --target-dir "$SCRIPT_DIR/target/jolt-guest" --features guest
    echo "=== Building host binary ==="
    cargo +nightly build --release --bin sha2-bench
    echo "Done."
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
    echo "Usage: $0 [build|build-guest|build-host|run|install-cli]"
    echo "  install-cli  Install jolt CLI tool (one-time setup)"
    echo "  build        Build guest ELFs + host binary locally"
    echo "  build-guest  Build guest ELFs only"
    echo "  build-host   Build host binary only"
    echo "  run          Run benchmark (MODE=execute|prove, N=<iters>, INLINE=true|false)"
    echo ""
    echo "Setup:"
    echo "  rustup target add riscv64imac-unknown-none-elf"
    echo "  ./run.sh install-cli"
    echo "  ./run.sh build"
    echo "  N=1000 MODE=prove INLINE=true ./run.sh run"
    exit 1
    ;;
esac
