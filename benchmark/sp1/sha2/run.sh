#!/bin/bash
set -e

N=${N:-256}
MODE=${MODE:-execute}            # execute | prove
PROOF_MODE=${PROOF_MODE:-core}   # core | compressed | groth16
INPUT_SIZE=${INPUT_SIZE:-32}     # input data size in bytes
PRECOMPILE=${PRECOMPILE:-false}  # true | false (use SP1 precompile for SHA-256)
CMD=${1:-run}                    # build | run | download-params

SP1_CIRCUIT_VERSION="v6.0.0"
S3_BASE="https://sp1-circuits.s3-us-east-2.amazonaws.com"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "$CMD" in
  build)
    # Build both CPU and GPU binaries
    cd "$SCRIPT_DIR"
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
    cargo build --release --bin sha2-bench
    cp "$SCRIPT_DIR/target/release/sha2-bench" "$SCRIPT_DIR/target/release/sha2-bench-cpu"
    ;;
  build-gpu)
    cd "$SCRIPT_DIR"
    cargo build --release --bin sha2-bench --features cuda
    cp "$SCRIPT_DIR/target/release/sha2-bench" "$SCRIPT_DIR/target/release/sha2-bench-gpu"
    ;;
  run)
    # Select binary: GPU if SP1_PROVER=cuda, else CPU
    if [ "${SP1_PROVER:-cpu}" = "cuda" ]; then
        BIN="$SCRIPT_DIR/target/release/sha2-bench-gpu"
    else
        BIN="$SCRIPT_DIR/target/release/sha2-bench-cpu"
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
        "--${MODE}" --n "$N" --mode "$PROOF_MODE" --input-size "$INPUT_SIZE" \
        $([ "$PRECOMPILE" = "true" ] && echo "--precompile") 2>/dev/null)
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
  *)
    echo "Usage: $0 [build|build-cpu|build-gpu|run|download-params]"
    echo "  build            Build both CPU and GPU binaries"
    echo "  build-cpu        Build CPU-only binary"
    echo "  build-gpu        Build GPU (CUDA) binary"
    echo "  run              Run benchmark (SP1_PROVER=cpu|cuda|mock)"
    echo "  download-params  Pre-download Groth16 circuit params (~1GB)"
    exit 1
    ;;
esac
