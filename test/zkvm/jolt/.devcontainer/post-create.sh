#!/usr/bin/env bash
set -euo pipefail

echo "=== Setting up Jolt + ZeroOS environment ==="

# Install Rust 1.90 (required for ZeroOS target spec compatibility)
echo "Installing Rust 1.90..."
rustup install 1.90
rustup default 1.90
rustup component add rust-src --toolchain 1.90

# Install cargo-jolt
echo "Installing cargo-jolt..."
cargo install --git https://github.com/LayerZero-Research/jolt.git --branch gx/integrate-zeroos jolt-build

echo ""
echo "=== Setup Complete ==="
echo "Run: cargo run --release -p multithread-test"
