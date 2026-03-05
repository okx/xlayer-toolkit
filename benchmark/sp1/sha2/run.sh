#!/bin/bash
set -e

IMAGE=${IMAGE:-sp1-sha2}
N=${N:-256}
MODE=${MODE:-execute}            # execute | prove
PROOF_MODE=${PROOF_MODE:-core}   # core | compressed | groth16
INPUT_SIZE=${INPUT_SIZE:-32}     # input data size in bytes
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
    DOCKER_FLAGS=""
    if [ "$PROOF_MODE" = "groth16" ]; then
        DOCKER_FLAGS="-v /var/run/docker.sock:/var/run/docker.sock \
            -v $HOME/.sp1:$HOME/.sp1 -e HOME=$HOME \
            -e TMPDIR=$HOME/.sp1/tmp"
    fi
    docker run --rm \
        -v sp1-params:/root/.sp1 \
        $DOCKER_FLAGS \
        -e SP1_PROVER="${SP1_PROVER:-cpu}" \
        -e NETWORK_PRIVATE_KEY="${NETWORK_PRIVATE_KEY:-}" \
        "$IMAGE" \
        "--${MODE}" --n "$N" --mode "$PROOF_MODE" --input-size "$INPUT_SIZE"
    ;;
  download-params)
    PARAM_DIR="$HOME/.sp1/circuits/groth16/${SP1_CIRCUIT_VERSION}"

    # 1) Download and extract Groth16 circuit params
    if [ -f "$PARAM_DIR/groth16_pk.bin" ]; then
        echo "Circuit params already exist at $PARAM_DIR, skipping download."
    else
        DL_TMPDIR=$(mktemp -d)
        trap "rm -rf $DL_TMPDIR" EXIT
        URL="${S3_BASE}/${SP1_CIRCUIT_VERSION}-groth16.tar.gz"
        echo "[1/3] Downloading Groth16 params from: $URL"
        curl -L --progress-bar -o "$DL_TMPDIR/groth16.tar.gz" "$URL"
        echo "Size: $(ls -lh "$DL_TMPDIR/groth16.tar.gz" | awk '{print $5}')"
        mkdir -p "$PARAM_DIR"
        tar xzf "$DL_TMPDIR/groth16.tar.gz" -C "$PARAM_DIR"
        echo "Params installed to $PARAM_DIR"
    fi

    # 2) Pull arm64 gnark image if on Apple Silicon (v6.0.0 manifest lacks arm64)
    ARCH=$(uname -m)
    GNARK_IMAGE="ghcr.io/succinctlabs/sp1-gnark:${SP1_CIRCUIT_VERSION}"
    if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
        if docker image inspect "$GNARK_IMAGE" >/dev/null 2>&1; then
            echo "[2/3] Gnark image $GNARK_IMAGE already exists, skipping."
        else
            ARM64_TAG="f87f8d6ff005d542db22e241928319f5e96a4609-arm64"
            echo "[2/3] Pulling arm64 gnark image and tagging as ${SP1_CIRCUIT_VERSION}..."
            docker pull "ghcr.io/succinctlabs/sp1-gnark:${ARM64_TAG}"
            docker tag "ghcr.io/succinctlabs/sp1-gnark:${ARM64_TAG}" "$GNARK_IMAGE"
        fi
    else
        echo "[2/3] x86_64 detected, gnark image will be pulled automatically."
    fi

    # 3) Create tmp dir for Groth16 Docker-in-Docker witness exchange
    mkdir -p "$HOME/.sp1/tmp"
    echo "[3/3] Created $HOME/.sp1/tmp"

    echo "Done. Groth16 is ready to use."
    ;;
  *)
    echo "Usage: $0 [build|run|download-params]"
    echo "  build            Build the Docker image"
    echo "  run              Run benchmark (N=256|512, MODE=execute|prove, PROOF_MODE=core|compressed|groth16, INPUT_SIZE=32)"
    echo "  download-params  Pre-download Groth16 circuit params (~1GB) into Docker volume"
    exit 1
    ;;
esac
