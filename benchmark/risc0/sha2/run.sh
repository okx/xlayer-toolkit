#!/bin/bash
set -e

N=${N:-256}
MODE=${MODE:-execute}            # execute | prove
PROOF_MODE=${PROOF_MODE:-composite}  # composite | succinct | groth16
INPUT_SIZE=${INPUT_SIZE:-32}     # input data size in bytes
PRECOMPILE=${PRECOMPILE:-false}  # true | false (use RISC Zero precompile for SHA-256)
CMD=${1:-run}                    # build | run | download-params

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Pre-downloaded recursion circuit artifacts (used by risc0-circuit-recursion build.rs)
RISC0_CACHE_DIR="$HOME/.risc0/cache"
RECURSION_ZKR="$RISC0_CACHE_DIR/recursion_zkr_744b999f.zip"
RECURSION_ZKR_URL="https://risc0-artifacts.s3.us-west-2.amazonaws.com/zkr/744b999f0a35b3c86753311c7efb2a0054be21727095cf105af6ee7d3f4d8849.zip"

case "$CMD" in
  build)
    cd "$SCRIPT_DIR"
    # Use pre-downloaded recursion zkr if available
    if [ -f "$RECURSION_ZKR" ]; then
        echo "Using cached recursion zkr: $RECURSION_ZKR"
        export RECURSION_SRC_PATH="$RECURSION_ZKR"
    fi
    echo "=== Building CPU binary ==="
    cargo build --release --bin sha2-bench
    cp "$SCRIPT_DIR/target/release/sha2-bench" "$SCRIPT_DIR/target/release/sha2-bench-cpu"
    echo "=== Building GPU binary ==="
    cargo build --release --bin sha2-bench --features cuda
    cp "$SCRIPT_DIR/target/release/sha2-bench" "$SCRIPT_DIR/target/release/sha2-bench-gpu"
    echo "Done. Binaries: target/release/sha2-bench-cpu, target/release/sha2-bench-gpu"
    ;;
  build-cpu)
    cd "$SCRIPT_DIR"
    if [ -f "$RECURSION_ZKR" ]; then
        export RECURSION_SRC_PATH="$RECURSION_ZKR"
    fi
    cargo build --release --bin sha2-bench
    cp "$SCRIPT_DIR/target/release/sha2-bench" "$SCRIPT_DIR/target/release/sha2-bench-cpu"
    ;;
  build-gpu)
    cd "$SCRIPT_DIR"
    if [ -f "$RECURSION_ZKR" ]; then
        export RECURSION_SRC_PATH="$RECURSION_ZKR"
    fi
    cargo build --release --bin sha2-bench --features cuda
    cp "$SCRIPT_DIR/target/release/sha2-bench" "$SCRIPT_DIR/target/release/sha2-bench-gpu"
    ;;
  run)
    # Select binary: GPU if RISC0_CUDA=1, else CPU
    if [ "${RISC0_CUDA:-}" = "1" ] || [ "${RISC0_CUDA:-}" = "true" ]; then
        BIN="$SCRIPT_DIR/target/release/sha2-bench-gpu"
    else
        BIN="$SCRIPT_DIR/target/release/sha2-bench-cpu"
    fi
    if [ ! -f "$BIN" ]; then
        echo "Error: $BIN not found. Run './run.sh build' first." >&2
        exit 1
    fi
    RUST_LOG="${RUST_LOG:-debug}" \
    RISC0_PROVER="${RISC0_PROVER:-local}" \
        "$BIN" \
        "--${MODE}" --n "$N" --mode "$PROOF_MODE" --input-size "$INPUT_SIZE" \
        $([ "$PRECOMPILE" = "true" ] && echo "--precompile")
    ;;
  download-params)
    if [ -f "$RECURSION_ZKR" ]; then
        echo "Recursion zkr already exists at $RECURSION_ZKR, skipping download."
    else
        mkdir -p "$RISC0_CACHE_DIR"
        echo "Downloading recursion zkr from: $RECURSION_ZKR_URL"
        curl -L --progress-bar -o "$RECURSION_ZKR" "$RECURSION_ZKR_URL"
        echo "Saved to $RECURSION_ZKR ($(ls -lh "$RECURSION_ZKR" | awk '{print $5}'))"
    fi
    echo "Done. Run './run.sh build' to build with cached artifacts."
    ;;
  *)
    echo "Usage: $0 [build|build-cpu|build-gpu|run|download-params]"
    echo "  build            Build both CPU and GPU binaries"
    echo "  build-cpu        Build CPU-only binary"
    echo "  build-gpu        Build GPU (CUDA) binary"
    echo "  run              Run benchmark (RISC0_CUDA=1 selects GPU binary)"
    echo "  download-params  Pre-download recursion circuit artifacts (~100MB)"
    exit 1
    ;;
esac
