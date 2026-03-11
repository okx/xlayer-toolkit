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
    # Guest ELF compiled locally via build.rs (requires succinct toolchain).
    # Host binary compiled natively. native-gnark: Groth16 uses CGo.
    cd "$SCRIPT_DIR"
    FEATURES=""
    if [ "${SP1_PROVER:-}" = "cuda" ]; then
        FEATURES="--features cuda"
    fi
    cargo build --release --bin fibonacci $FEATURES
    ;;
  run)
    # sp1-cuda cleanup panics on exit (tokio runtime missing in Drop).
    # Capture output, print stdout only, ignore crash exit code.
    set +e
    OUTPUT=$(RUST_LOG="${RUST_LOG:-info}" \
    SP1_PROVER="${SP1_PROVER:-cpu}" \
        "$SCRIPT_DIR/target/release/fibonacci" \
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
  *)
    echo "Usage: $0 [build|run|download-params]"
    echo "  build            Build the binary (guest ELF via Docker, host natively)"
    echo "                   Set SP1_PROVER=cuda to build with CUDA support"
    echo "  run              Run benchmark (SP1_PROVER=cpu|cuda|mock|network)"
    echo "  download-params  Pre-download Groth16 circuit params (~1GB)"
    exit 1
    ;;
esac
