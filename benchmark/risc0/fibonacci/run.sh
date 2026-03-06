#!/bin/bash
set -e

IMAGE=${IMAGE:-risc0-fibonacci}
N=${N:-20}
MODE=${MODE:-execute}            # execute | prove
PROOF_MODE=${PROOF_MODE:-composite}  # composite | succinct | groth16
CMD=${1:-run}                    # build | run

# Build context must be benchmark/ root to include shared utils crate
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_CONTEXT="$SCRIPT_DIR/../.."

case "$CMD" in
  build)
    docker build -t "$IMAGE" -f "$SCRIPT_DIR/Dockerfile" "$BUILD_CONTEXT"
    ;;
  run)
    docker run --rm \
        -e RUST_LOG="${RUST_LOG:-debug}" \
        -e RISC0_PROVER="${RISC0_PROVER:-local}" \
        "$IMAGE" \
        "--${MODE}" --n "$N" --mode "$PROOF_MODE"
    ;;
  *)
    echo "Usage: $0 [build|run]"
    echo "  build   Build the Docker image"
    echo "  run     Run benchmark (MODE=execute|prove, N=<n>, PROOF_MODE=composite|succinct|groth16)"
    exit 1
    ;;
esac
