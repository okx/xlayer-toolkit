#!/bin/bash
set -e

IMAGE="sp1-fibonacci"
N=${N:-20}
MODE=${MODE:-execute}  # execute | prove
CMD=${1:-run}          # build | run

case "$CMD" in
  build)
    docker build -t "$IMAGE" .
    ;;
  run)
    docker run --rm \
        -e SP1_PROVER="${SP1_PROVER:-cpu}" \
        -e NETWORK_PRIVATE_KEY="${NETWORK_PRIVATE_KEY:-}" \
        "$IMAGE" \
        "--${MODE}" --n "$N"
    ;;
  *)
    echo "Usage: $0 [build|run]"
    echo "  build        Build the Docker image (compile ELF + script binary)"
    echo "  run          Run benchmark (MODE=execute|prove, N=<n>)"
    exit 1
    ;;
esac
