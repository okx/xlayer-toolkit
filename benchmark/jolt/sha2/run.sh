#!/bin/bash
set -e

N=${N:-1000}
MODE=${MODE:-execute}            # execute | prove
INLINE=${INLINE:-false}          # true | false
INPUT_SIZE=${INPUT_SIZE:-32}     # input size in bytes
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
    # Build inline variant (use RUSTFLAGS --cfg inline since jolt build overrides --features)
    echo "  Building inline guest..."
    RUSTFLAGS="--cfg inline" jolt build -p sha2-guest --backtrace off --stack-size 4096 \
        -- --release --target-dir "$SCRIPT_DIR/target/jolt-guest" --features guest
    # Build native variant
    echo "  Building native guest..."
    jolt build -p sha2-guest --backtrace off --stack-size 4096 \
        -- --release --target-dir "$SCRIPT_DIR/target/jolt-guest" --features guest
    echo "Guest ELFs built."
    ;;
  build-host)
    cd "$SCRIPT_DIR"
    echo "Building host binaries..."
    # Build native (default) binary
    echo "  Building native binary..."
    cargo +nightly build --release --bin sha2-bench
    cp "$SCRIPT_DIR/target/release/sha2-bench" "$SCRIPT_DIR/target/release/sha2-bench-native"
    # Build inline binary (RUSTFLAGS --cfg inline for guest crate, --features inline for host)
    echo "  Building inline binary..."
    RUSTFLAGS="--cfg inline" cargo +nightly build --release --bin sha2-bench --features inline
    cp "$SCRIPT_DIR/target/release/sha2-bench" "$SCRIPT_DIR/target/release/sha2-bench-inline"
    echo "Host binaries built."
    ;;
  build)
    # Build both guest ELFs and host binaries
    cd "$SCRIPT_DIR"
    echo "=== Building guest ELFs ==="
    "$0" build-guest
    echo "=== Building host binaries ==="
    "$0" build-host
    echo "Done."
    ;;
  run)
    if [ "$INLINE" = "true" ]; then
        BIN="$SCRIPT_DIR/target/release/sha2-bench-inline"
        INLINE_FLAG="--inline"
    else
        BIN="$SCRIPT_DIR/target/release/sha2-bench-native"
        INLINE_FLAG=""
    fi
    if [ ! -f "$BIN" ]; then
        echo "Error: $BIN not found. Run './run.sh build' first." >&2
        exit 1
    fi
    RUST_LOG="${RUST_LOG:-info}" \
        "$BIN" "--${MODE}" --n "$N" --input-size "$INPUT_SIZE" $INLINE_FLAG
    ;;
  *)
    echo "Usage: $0 [build|build-guest|build-host|run|install-cli]"
    echo "  install-cli  Install jolt CLI tool (one-time setup)"
    echo "  build        Build guest ELFs + host binaries locally"
    echo "  build-guest  Build guest ELFs only"
    echo "  build-host   Build host binaries only"
    echo "  run          Run benchmark (MODE=execute|prove, N=<iters>, INPUT_SIZE=<bytes>, INLINE=true|false)"
    echo ""
    echo "Setup:"
    echo "  rustup target add riscv64imac-unknown-none-elf"
    echo "  ./run.sh install-cli"
    echo "  ./run.sh build"
    echo "  N=1000 INPUT_SIZE=256 MODE=prove INLINE=true ./run.sh run"
    exit 1
    ;;
esac
