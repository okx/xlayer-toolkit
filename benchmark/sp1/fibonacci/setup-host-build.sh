#!/bin/bash
set -e

SP1_VERSION="${SP1_VERSION:-v6.0.2}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAX_RETRIES=5
RETRY_DELAY=3

echo "=== SP1 Host Build Setup (no Docker) ==="
echo "SP1 version: $SP1_VERSION"
echo ""

# ─── Step 1: Install sp1up + cargo-prove ───
if ! command -v ~/.sp1/bin/cargo-prove &>/dev/null; then
    echo "[1/4] Installing sp1up..."
    curl -L https://sp1up.succinct.xyz | bash
    export PATH="$HOME/.sp1/bin:$PATH"
    sp1up --version "$SP1_VERSION"
else
    echo "[1/4] cargo-prove already installed, skipping sp1up."
    export PATH="$HOME/.sp1/bin:$PATH"
fi

# ─── Step 2: Install succinct toolchain (with retry) ───
if rustup toolchain list 2>/dev/null | grep -q succinct; then
    echo "[2/4] succinct toolchain already installed."
else
    echo "[2/4] Installing succinct toolchain (with retries for flaky network)..."
    INSTALLED=false
    for i in $(seq 1 $MAX_RETRIES); do
        echo "  Attempt $i/$MAX_RETRIES..."
        if ~/.sp1/bin/cargo-prove prove install-toolchain 2>&1; then
            INSTALLED=true
            break
        fi
        echo "  Failed, retrying in ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
        RETRY_DELAY=$((RETRY_DELAY * 2))
    done

    if [ "$INSTALLED" = false ]; then
        echo ""
        echo "ERROR: Failed to install toolchain after $MAX_RETRIES attempts."
        echo ""
        echo "Manual fix: download from GitHub on another machine and scp over."
        echo "  1. On a machine with GitHub access, run:"
        echo "     curl -L https://api.github.com/repos/succinctlabs/rust/releases | jq '.[0].assets[] | select(.name | contains(\"linux\"))'"
        echo "  2. Download the toolchain tar.gz"
        echo "  3. scp it to this machine and extract to ~/.rustup/toolchains/succinct/"
        echo ""
        echo "Or set a proxy:"
        echo "  export https_proxy=http://your-proxy:port"
        echo "  $0"
        exit 1
    fi
fi

# Verify
echo "  Verifying toolchain..."
if ! rustup run succinct rustc --version; then
    echo "ERROR: succinct toolchain installed but not working."
    exit 1
fi
echo "  OK."

# ─── Step 3: Patch build.rs to docker: false ───
BUILD_RS="$SCRIPT_DIR/script/build.rs"
echo "[3/4] Patching build.rs -> docker: false"
if grep -q 'docker: true' "$BUILD_RS"; then
    sed -i 's/docker: true/docker: false/' "$BUILD_RS"
    echo "  Patched."
else
    echo "  Already set to docker: false, skipping."
fi

# ─── Step 4: Clean and build ───
echo "[4/4] Building fibonacci (host mode)..."
cd "$SCRIPT_DIR"
cargo clean
SP1_PROVER="${SP1_PROVER:-cuda}" cargo build --release --bin fibonacci ${SP1_PROVER:+--features cuda} -vv

echo ""
echo "=== Done! Build succeeded without Docker. ==="
echo "Run with: SP1_PROVER=cuda ./run.sh run"
