#!/bin/bash
set -e

JOLT_REV="2e05fe883920054df2ee3a6df8f85c2caba77c99"

echo "=== Installing Rust nightly toolchain ==="
rustup install nightly
rustup default nightly

echo "=== Adding RISC-V target ==="
rustup target add riscv64imac-unknown-none-elf

echo "=== Installing jolt CLI (rev: ${JOLT_REV:0:8}) ==="
cargo install --git https://github.com/a16z/jolt --rev "$JOLT_REV" --force --bins jolt

echo "=== Setup complete ==="
echo "You can now run:"
echo "  ./run.sh build    # compile host binary"
echo "  N=1000 MODE=prove INLINE=true ./run.sh run   # with inline optimization"
echo "  N=1000 MODE=prove INLINE=false ./run.sh run   # without inline optimization"
