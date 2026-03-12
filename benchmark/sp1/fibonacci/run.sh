#!/bin/bash
set -e

N=${N:-20}
MODE=${MODE:-execute}            # execute | prove
PROOF_MODE=${PROOF_MODE:-core}   # core | compressed | groth16
CMD=${1:-run}                    # build | run | download-params

SP1_CIRCUIT_VERSION="v6.0.0"
S3_BASE="https://sp1-circuits.s3-us-east-2.amazonaws.com"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Enable AVX2 SIMD acceleration (Plonky3 hot path)
export RUSTFLAGS="${RUSTFLAGS:--C target-cpu=native}"

case "$CMD" in
  build)
    # Build both CPU and GPU binaries
    cd "$SCRIPT_DIR"
    echo "=== Building CPU binary (RUSTFLAGS=$RUSTFLAGS) ==="
    cargo build --release --bin fibonacci
    cp "$SCRIPT_DIR/target/release/fibonacci" "$SCRIPT_DIR/target/release/fibonacci-cpu"
    echo "=== Building GPU binary ==="
    cargo build --release --bin fibonacci --features cuda
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
    cargo build --release --bin fibonacci --features cuda
    cp "$SCRIPT_DIR/target/release/fibonacci" "$SCRIPT_DIR/target/release/fibonacci-gpu"
    ;;
  build-groth16-gpu)
    # Build with icicle GPU acceleration for Groth16 proving
    # Requires icicle CUDA libs in /usr/local/lib (or ICICLE_BACKEND_INSTALL_DIR)
    cd "$SCRIPT_DIR"
    cargo build --release --bin fibonacci --features cuda,groth16-cuda
    cp "$SCRIPT_DIR/target/release/fibonacci" "$SCRIPT_DIR/target/release/fibonacci-groth16-gpu"
    ;;
  run)
    # Select binary based on SP1_PROVER and PROOF_MODE
    if [ "${SP1_PROVER:-cpu}" = "cuda" ] && [ "$PROOF_MODE" = "groth16" ] \
       && [ -f "$SCRIPT_DIR/target/release/fibonacci-groth16-gpu" ]; then
        BIN="$SCRIPT_DIR/target/release/fibonacci-groth16-gpu"
    elif [ "${SP1_PROVER:-cpu}" = "cuda" ]; then
        BIN="$SCRIPT_DIR/target/release/fibonacci-gpu"
    else
        BIN="$SCRIPT_DIR/target/release/fibonacci-cpu"
    fi
    if [ ! -f "$BIN" ]; then
        echo "Error: $BIN not found. Run './run.sh build' first." >&2
        exit 1
    fi
    # sp1-cuda cleanup panics on exit (tokio runtime missing in Drop).
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
    # Download and install icicle CUDA backend libs (required for build-groth16-gpu)
    ICICLE_VERSION="${ICICLE_VERSION:-3.4.0}"
    ICICLE_INSTALL_DIR="${ICICLE_BACKEND_INSTALL_DIR:-/usr/local/lib}"
    ICICLE_TAG="icicle_$(echo "$ICICLE_VERSION" | tr '.' '_')"
    ICICLE_TARBALL="${ICICLE_TAG}-ubuntu22-cuda122.tar.gz"
    ICICLE_URL="https://github.com/ingonyama-zk/icicle/releases/download/v${ICICLE_VERSION}/${ICICLE_TARBALL}"

    # Check if already installed
    if [ -f "${ICICLE_INSTALL_DIR}/libicicle_device.so" ] && \
       [ -f "${ICICLE_INSTALL_DIR}/libicicle_field_bn254.so" ]; then
        echo "Icicle libs already found in ${ICICLE_INSTALL_DIR}, skipping."
        echo "To reinstall, remove ${ICICLE_INSTALL_DIR}/libicicle_*.so first."
    else
        DL_TMPDIR=$(mktemp -d)
        trap "rm -rf $DL_TMPDIR" EXIT
        echo "Downloading icicle v${ICICLE_VERSION} CUDA backend..."
        echo "  URL: $ICICLE_URL"
        curl -L --progress-bar -o "$DL_TMPDIR/icicle.tar.gz" "$ICICLE_URL"
        echo "Size: $(ls -lh "$DL_TMPDIR/icicle.tar.gz" | awk '{print $5}')"

        echo "Extracting to $DL_TMPDIR/icicle ..."
        mkdir -p "$DL_TMPDIR/icicle"
        tar xzf "$DL_TMPDIR/icicle.tar.gz" -C "$DL_TMPDIR/icicle"

        echo "Installing to ${ICICLE_INSTALL_DIR} (requires sudo)..."
        sudo mkdir -p "${ICICLE_INSTALL_DIR}"
        # Copy all .so files to install dir
        sudo find "$DL_TMPDIR/icicle" -name '*.so' -exec cp -v {} "${ICICLE_INSTALL_DIR}/" \;
        sudo ldconfig
        echo ""
        echo "Installed icicle libs:"
        ls -lh "${ICICLE_INSTALL_DIR}"/libicicle_*.so 2>/dev/null || echo "  (none found)"
    fi

    echo ""
    echo "Done. You can now run: ./run.sh build-groth16-gpu"
    ;;
  *)
    echo "Usage: $0 [build|build-cpu|build-gpu|build-groth16-gpu|run|download-params|install-icicle]"
    echo "  build              Build both CPU and GPU binaries"
    echo "  build-cpu          Build CPU-only binary"
    echo "  build-gpu          Build GPU (CUDA) binary"
    echo "  build-groth16-gpu  Build GPU binary with icicle Groth16 acceleration"
    echo "  run                Run benchmark (SP1_PROVER=cpu|cuda|mock)"
    echo "  download-params    Pre-download Groth16 circuit params (~1GB)"
    echo "  install-icicle     Download & install icicle CUDA libs (for Groth16 GPU)"
    exit 1
    ;;
esac
