#!/bin/bash
set -e

N=${N:-20}
MODE=${MODE:-execute}            # execute | prove
PROOF_MODE=${PROOF_MODE:-composite}  # composite | succinct | groth16
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
    FEATURES=""
    if [ "${RISC0_PROVER:-}" = "cuda" ]; then
        FEATURES="--features cuda"
    fi
    cargo build --release --bin fibonacci-bench $FEATURES
    ;;
  run)
    RUST_LOG="${RUST_LOG:-info}" \
    RISC0_PROVER="${RISC0_PROVER:-local}" \
        "$SCRIPT_DIR/target/release/fibonacci-bench" \
        "--${MODE}" --n "$N" --mode "$PROOF_MODE"
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
    echo "Usage: $0 [build|run|download-params]"
    echo "  build            Build the binary (guest ELF via Docker, host natively)"
    echo "  run              Run benchmark (MODE=execute|prove, N=<n>, PROOF_MODE=composite|succinct|groth16)"
    echo "  download-params  Pre-download recursion circuit artifacts (~100MB)"
    exit 1
    ;;
esac
