#!/bin/bash
set -e

# One-time setup for zkVM benchmarks on a fresh Ubuntu machine.
# Prerequisites: Docker and NVIDIA drivers already installed.
#
# Covers: system deps, Go, Rust, SP1 toolchain, RISC Zero toolchain,
#         Docker group, and GitHub DNS workaround for restricted networks.
#
# Usage:
#   chmod +x setup-ubuntu.sh
#   ./setup-ubuntu.sh

# ─── 1. GitHub DNS fix (for cloud networks that cannot resolve github.com) ───
echo "=== Checking GitHub DNS resolution ==="
if ping -c 1 -W 3 github.com &>/dev/null; then
    echo "github.com reachable, skipping DNS fix."
else
    echo "github.com unreachable — adding GitHub IPs to /etc/hosts"
    sudo bash -c 'cat >> /etc/hosts << EOF

# GitHub (added by setup-ubuntu.sh for cloud networks)
20.205.243.166  github.com
20.205.243.168  api.github.com
185.199.109.133 objects.githubusercontent.com
185.199.110.133 objects.githubusercontent.com
185.199.111.133 objects.githubusercontent.com
185.199.108.133 objects.githubusercontent.com
EOF'
    echo "Added. Verifying..."
    if ! ping -c 1 -W 3 github.com &>/dev/null; then
        echo "WARNING: github.com still unreachable. IPs may have changed."
        echo "Resolve on another machine: nslookup github.com / api.github.com / objects.githubusercontent.com"
        echo "Then update /etc/hosts manually."
    else
        echo "github.com reachable now."
    fi
fi

# ─── 2. System dependencies ───
echo ""
echo "=== Installing system dependencies ==="
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    pkg-config \
    libssl-dev \
    libclang-dev \
    protobuf-compiler

# ─── 3. Go 1.24 (required by SP1 native-gnark) ───
echo ""
echo "=== Installing Go 1.24 ==="
if command -v go &>/dev/null && go version | grep -q "go1.2[4-9]"; then
    echo "Go $(go version | awk '{print $3}') already installed, skipping."
else
    sudo rm -rf /usr/local/go
    wget -q https://go.dev/dl/go1.24.1.linux-amd64.tar.gz -O /tmp/go.tar.gz
    sudo tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    grep -q '/usr/local/go/bin' ~/.bashrc || echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
    export PATH=$PATH:/usr/local/go/bin
    echo "Go $(go version | awk '{print $3}') installed."
fi

# ─── 4. Rust ───
echo ""
echo "=== Installing Rust ==="
if command -v rustc &>/dev/null; then
    echo "Rust $(rustc --version | awk '{print $2}') already installed, skipping."
else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
    echo "Rust $(rustc --version | awk '{print $2}') installed."
fi

# ─── 5. SP1 toolchain (succinct) ───
echo ""
echo "=== Installing SP1 succinct toolchain ==="
if rustup run succinct rustc --version &>/dev/null; then
    echo "succinct toolchain already installed: $(rustup run succinct rustc --version)"
else
    echo "Downloading succinct toolchain from GitHub releases..."
    SP1_TOOLCHAIN_URL="https://github.com/succinctlabs/rust/releases/download/succinct-1.93.0-64bit/rust-toolchain-x86_64-unknown-linux-gnu.tar.gz"
    mkdir -p ~/.rustup/toolchains/succinct
    if curl -L --progress-bar "$SP1_TOOLCHAIN_URL" | tar -xz -C ~/.rustup/toolchains/succinct --strip-components=1; then
        echo "succinct toolchain installed: $(rustup run succinct rustc --version)"
    else
        echo "WARNING: Failed to download SP1 toolchain."
        echo "Manual fix: download on another machine and scp over:"
        echo "  curl -L -o toolchain.tar.gz '$SP1_TOOLCHAIN_URL'"
        echo "  scp toolchain.tar.gz user@this-machine:~/"
        echo "  mkdir -p ~/.rustup/toolchains/succinct"
        echo "  tar -xzf ~/toolchain.tar.gz -C ~/.rustup/toolchains/succinct --strip-components=1"
    fi
fi

# ─── 6. SP1 cargo-prove (sp1up) ───
echo ""
echo "=== Installing SP1 cargo-prove ==="
if [ -f "$HOME/.sp1/bin/cargo-prove" ]; then
    echo "cargo-prove already installed."
else
    echo "Installing sp1up..."
    curl -L https://sp1up.succinct.xyz | bash
    export PATH="$HOME/.sp1/bin:$PATH"
    sp1up --version v6.0.2
    grep -q '.sp1/bin' ~/.bashrc || echo 'export PATH=$PATH:$HOME/.sp1/bin' >> ~/.bashrc
    echo "SP1 cargo-prove installed."
fi

# ─── 7. RISC Zero toolchain (rzup) ───
echo ""
echo "=== Installing RISC Zero toolchain ==="
if command -v rzup &>/dev/null; then
    echo "rzup already installed, checking toolchain..."
    rzup install rust 2>/dev/null || true
    echo "RISC Zero toolchain ready."
else
    curl -L https://risczero.com/install | bash
    export PATH="$HOME/.risc0/bin:$PATH"
    rzup install
    grep -q '.risc0/bin' ~/.bashrc || echo 'export PATH=$PATH:$HOME/.risc0/bin' >> ~/.bashrc
    echo "RISC Zero toolchain installed."
fi

# ─── 8. Docker group ───
echo ""
echo "=== Docker group ==="
if groups | grep -q docker; then
    echo "Already in docker group."
else
    sudo usermod -aG docker "$USER"
    echo "Added to docker group. Run 'newgrp docker' or re-login to apply."
fi

# ─── Summary ───
echo ""
echo "========================================="
echo "  Setup complete!"
echo "========================================="
echo ""
echo "If you were just added to the docker group, run:"
echo "  newgrp docker"
echo ""
echo "SP1 Fibonacci (GPU):"
echo "  cd sp1/fibonacci"
echo "  SP1_PROVER=cuda ./run.sh build"
echo "  SP1_PROVER=cuda N=32768 MODE=prove PROOF_MODE=compressed ./run.sh run"
echo ""
echo "RISC Zero Fibonacci (GPU):"
echo "  cd risc0/fibonacci"
echo "  RISC0_CUDA=1 ./run.sh build"
echo "  N=32768 MODE=prove PROOF_MODE=composite ./run.sh run"
