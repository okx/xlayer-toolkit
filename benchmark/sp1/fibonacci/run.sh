#!/bin/bash
set -e

N=${N:-20}
MODE=${MODE:-execute}            # execute | prove
PROOF_MODE=${PROOF_MODE:-core}   # core | compressed | groth16
CMD=${1:-run}                    # build | run | download-params

SP1_CIRCUIT_VERSION="v6.0.0"
S3_BASE="https://sp1-circuits.s3-us-east-2.amazonaws.com"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "$CMD" in
  build)
    # Guest ELF compiled in Docker via build.rs (docker: true),
    # host binary compiled natively — runs directly on host.
    cd "$SCRIPT_DIR"
    cargo build --release --bin fibonacci
    ;;
  run)
    RUST_LOG="${RUST_LOG:-info}" \
    SP1_PROVER="${SP1_PROVER:-cpu}" \
        "$SCRIPT_DIR/target/release/fibonacci" \
        "--${MODE}" --n "$N" --mode "$PROOF_MODE"
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
    echo "  build            Build the binary (guest ELF via Docker, host natively)"
    echo "  run              Run benchmark"
    echo "  download-params  Pre-download Groth16 circuit params (~1GB)"
    exit 1
    ;;
esac
