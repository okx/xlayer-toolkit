#!/bin/bash
set -e

N=${N:-20}
MODE=${MODE:-execute}            # execute | prove
PROOF_MODE=${PROOF_MODE:-core}   # core | compressed | groth16
CMD=${1:-run}                    # build | run | download-params | install-icicle

SP1_CIRCUIT_VERSION="v6.0.0"
S3_BASE="https://sp1-circuits.s3-us-east-2.amazonaws.com"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Enable AVX2 SIMD acceleration (Plonky3 hot path)
export RUSTFLAGS="${RUSTFLAGS:--C target-cpu=native}"

case "$CMD" in
  build)
    # Build CPU (AVX) + GPU (CUDA + icicle Groth16) binaries
    cd "$SCRIPT_DIR"
    echo "=== Building CPU binary (RUSTFLAGS=$RUSTFLAGS) ==="
    cargo build --release --bin fibonacci
    cp "$SCRIPT_DIR/target/release/fibonacci" "$SCRIPT_DIR/target/release/fibonacci-cpu"
    echo "=== Building GPU binary (cuda + groth16-cuda/icicle) ==="
    cargo build --release --bin fibonacci --features cuda,groth16-cuda
    cp "$SCRIPT_DIR/target/release/fibonacci" "$SCRIPT_DIR/target/release/fibonacci-gpu"
    echo "Done. Binaries: target/release/fibonacci-cpu, target/release/fibonacci-gpu"
    ;;
  build-cpu)
    cd "$SCRIPT_DIR"
    cargo build --release --bin fibonacci
    cp "$SCRIPT_DIR/target/release/fibonacci" "$SCRIPT_DIR/target/release/fibonacci-cpu"
    ;;
  build-gpu)
    cd "$SCRIPT_DIR"
    cargo build --release --bin fibonacci --features cuda,groth16-cuda
    cp "$SCRIPT_DIR/target/release/fibonacci" "$SCRIPT_DIR/target/release/fibonacci-gpu"
    ;;
  run)
    # Select binary: GPU if SP1_PROVER=cuda, else CPU
    if [ "${SP1_PROVER:-cpu}" = "cuda" ]; then
        BIN="$SCRIPT_DIR/target/release/fibonacci-gpu"
    else
        BIN="$SCRIPT_DIR/target/release/fibonacci-cpu"
    fi
    if [ ! -f "$BIN" ]; then
        echo "Error: $BIN not found. Run './run.sh build' first." >&2
        exit 1
    fi
    # sp1-cuda cleanup panics on exit (tokio runtime missing in Drop).
    # Set icicle backend path for Groth16 GPU acceleration
    export ICICLE_BACKEND_INSTALL_DIR="${ICICLE_BACKEND_INSTALL_DIR:-/usr/local/lib/backend}"
    set +e
    OUTPUT=$(RUST_LOG="${RUST_LOG:-info}" \
    SP1_PROVER="${SP1_PROVER:-cpu}" \
        "$BIN" \
        "--${MODE}" --n "$N" --mode "$PROOF_MODE" 2>/dev/null)
    set -e
    echo "$OUTPUT"
    ;;
  download-params)
    PARAM_DIR="$HOME/.sp1/circuits/groth16/${SP1_CIRCUIT_VERSION}"

    if [ -f "$PARAM_DIR/groth16_pk.bin" ]; then
        echo "Circuit params already exist at $PARAM_DIR, skipping download."
    else
        DL_TMPDIR=$(mktemp -d)
        trap "rm -rf $DL_TMPDIR" EXIT
        URL="${S3_BASE}/${SP1_CIRCUIT_VERSION}-groth16.tar.gz"
        echo "Downloading Groth16 params from: $URL"
        curl -L --progress-bar -o "$DL_TMPDIR/groth16.tar.gz" "$URL"
        echo "Size: $(ls -lh "$DL_TMPDIR/groth16.tar.gz" | awk '{print $5}')"
        mkdir -p "$PARAM_DIR"
        tar xzf "$DL_TMPDIR/groth16.tar.gz" -C "$PARAM_DIR"
        echo "Params installed to $PARAM_DIR"
    fi

    echo "Done. Groth16 is ready to use."
    ;;
  install-icicle)
    # Download and install icicle core + CUDA backend libs (required for build-gpu)
    # Two packages needed:
    #   1. Core libs (libicicle_device.so, libicicle_field_*.so, etc.) — linked at compile time
    #   2. CUDA backend (libicicle_backend_cuda_*.so) — loaded at runtime
    ICICLE_VERSION="${ICICLE_VERSION:-3.4.0}"
    ICICLE_INSTALL_DIR="${ICICLE_BACKEND_INSTALL_DIR:-/usr/local/lib}"
    # Asset naming: 3.4.0 → icicle_3_4, 3.9.2 → icicle_3_9_2 (trailing .0 is dropped)
    ICICLE_TAG="icicle_$(echo "$ICICLE_VERSION" | sed 's/\.0$//; s/\./_/g')"
    ICICLE_BASE="https://github.com/ingonyama-zk/icicle/releases/download/v${ICICLE_VERSION}"
    ICICLE_CORE="${ICICLE_TAG}-ubuntu22.tar.gz"
    ICICLE_CUDA="${ICICLE_TAG}-ubuntu22-cuda122.tar.gz"

    # Check if already installed
    if [ -f "${ICICLE_INSTALL_DIR}/libicicle_device.so" ] && \
       [ -f "${ICICLE_INSTALL_DIR}/libicicle_field_bn254.so" ] && \
       [ -f "${ICICLE_INSTALL_DIR}/libicicle_backend_cuda_device.so" ]; then
        echo "Icicle libs already found in ${ICICLE_INSTALL_DIR}, skipping."
        echo "To reinstall, remove ${ICICLE_INSTALL_DIR}/libicicle_*.so first."
    else
        DL_TMPDIR=$(mktemp -d)
        trap "rm -rf $DL_TMPDIR" EXIT

        echo "Downloading icicle v${ICICLE_VERSION} core libs..."
        curl -L --progress-bar -o "$DL_TMPDIR/core.tar.gz" "${ICICLE_BASE}/${ICICLE_CORE}"
        echo "Downloading icicle v${ICICLE_VERSION} CUDA backend..."
        curl -L --progress-bar -o "$DL_TMPDIR/cuda.tar.gz" "${ICICLE_BASE}/${ICICLE_CUDA}"

        mkdir -p "$DL_TMPDIR/extract"
        echo "Extracting core libs..."
        tar xzf "$DL_TMPDIR/core.tar.gz" -C "$DL_TMPDIR/extract"
        echo "Extracting CUDA backend..."
        tar xzf "$DL_TMPDIR/cuda.tar.gz" -C "$DL_TMPDIR/extract"

        echo "Installing core libs to ${ICICLE_INSTALL_DIR} (requires sudo)..."
        sudo mkdir -p "${ICICLE_INSTALL_DIR}"
        # Core libs go to /usr/local/lib (for compile-time linking)
        sudo find "$DL_TMPDIR/extract" -name 'libicicle_*.so' ! -name 'libicicle_backend_*' \
            -exec cp -v {} "${ICICLE_INSTALL_DIR}/" \;

        # CUDA backend libs go to /usr/local/lib/backend/ (loaded at runtime)
        BACKEND_DIR="${ICICLE_INSTALL_DIR}/backend"
        echo "Installing CUDA backend to ${BACKEND_DIR}..."
        sudo mkdir -p "${BACKEND_DIR}"
        sudo find "$DL_TMPDIR/extract" -name 'libicicle_backend_cuda_*.so' \
            -exec cp -v {} "${BACKEND_DIR}/" \;
        sudo ldconfig

        echo ""
        echo "Installed icicle core libs (${ICICLE_INSTALL_DIR}):"
        ls -1 "${ICICLE_INSTALL_DIR}"/libicicle_device.so \
              "${ICICLE_INSTALL_DIR}"/libicicle_field_bn254.so \
              "${ICICLE_INSTALL_DIR}"/libicicle_curve_bn254.so 2>/dev/null || echo "  (missing!)"
        echo "Installed icicle CUDA backend (${BACKEND_DIR}):"
        ls -1 "${BACKEND_DIR}"/libicicle_backend_cuda_device.so 2>/dev/null || echo "  (missing!)"
    fi

    echo ""
    echo "Done. You can now run: ./run.sh build"
    ;;
  *)
    echo "Usage: $0 [build|build-cpu|build-gpu|run|download-params|install-icicle]"
    echo "  build            Build CPU (AVX) + GPU (CUDA+icicle) binaries"
    echo "  build-cpu        Build CPU-only binary (AVX enabled)"
    echo "  build-gpu        Build GPU binary (CUDA + icicle Groth16)"
    echo "  run              Run benchmark (SP1_PROVER=cpu|cuda|mock)"
    echo "  download-params  Pre-download Groth16 circuit params (~1GB)"
    echo "  install-icicle   Download & install icicle CUDA libs (one-time setup)"
    exit 1
    ;;
esac
