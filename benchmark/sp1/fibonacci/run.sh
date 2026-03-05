#!/bin/bash
set -e

IMAGE=${IMAGE:-sp1-fibonacci}
N=${N:-20}
MODE=${MODE:-execute}            # execute | prove
PROOF_MODE=${PROOF_MODE:-core}   # core | compressed | groth16
CMD=${1:-run}                    # build | run | download-params

SP1_CIRCUIT_VERSION="v6.0.0"
S3_BASE="https://sp1-circuits.s3-us-east-2.amazonaws.com"

# Build context must be benchmark/ root to include shared utils crate
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_CONTEXT="$SCRIPT_DIR/../.."

case "$CMD" in
  build)
    docker build -t "$IMAGE" -f "$SCRIPT_DIR/Dockerfile" "$BUILD_CONTEXT"
    ;;
  run)
    docker run --rm \
        -v sp1-params:/root/.sp1 \
        -e SP1_PROVER="${SP1_PROVER:-cpu}" \
        -e NETWORK_PRIVATE_KEY="${NETWORK_PRIVATE_KEY:-}" \
        "$IMAGE" \
        "--${MODE}" --n "$N" --mode "$PROOF_MODE"
    ;;
  download-params)
    TMPDIR=$(mktemp -d)
    trap "rm -rf $TMPDIR" EXIT
    URL="${S3_BASE}/${SP1_CIRCUIT_VERSION}-groth16.tar.gz"
    echo "Downloading Groth16 params from: $URL"
    curl -L --progress-bar -o "$TMPDIR/groth16.tar.gz" "$URL"
    echo "Size: $(ls -lh "$TMPDIR/groth16.tar.gz" | awk '{print $5}')"
    echo "Installing into Docker volume sp1-params..."
    docker run --rm \
        -v sp1-params:/root/.sp1 \
        -v "$TMPDIR/groth16.tar.gz:/tmp/groth16.tar.gz" \
        debian:bookworm-slim \
        bash -c "mkdir -p /root/.sp1/circuits/${SP1_CIRCUIT_VERSION} && \
                 tar xzf /tmp/groth16.tar.gz -C /root/.sp1/circuits/${SP1_CIRCUIT_VERSION}"
    echo "Done. Params installed to sp1-params volume."
    ;;
  *)
    echo "Usage: $0 [build|run|download-params]"
    echo "  build            Build the Docker image"
    echo "  run              Run benchmark (MODE=execute|prove, N=<n>, PROOF_MODE=core|compressed|groth16)"
    echo "  download-params  Pre-download Groth16 circuit params (~1GB) into Docker volume"
    exit 1
    ;;
esac
