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
    cd "$SCRIPT_DIR"
    FEATURES=""
    if [ "${SP1_PROVER:-}" = "cuda" ]; then
        FEATURES="--features cuda"
    fi
    cargo build --release --bin sha2-bench $FEATURES
    ;;
  run)
    # sp1-cuda cleanup panics on exit (tokio runtime missing in Drop).
    set +e
    OUTPUT=$(RUST_LOG="${RUST_LOG:-info}" \
    SP1_PROVER="${SP1_PROVER:-cpu}" \
        "$SCRIPT_DIR/target/release/sha2-bench" \
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
    echo "Usage: $0 [build|run|download-params]"
    echo "  build            Build the binary (guest ELFs via Docker, host natively)"
    echo "  run              Run benchmark"
    echo "  download-params  Pre-download Groth16 circuit params (~1GB)"
    exit 1
    ;;
esac
