#!/bin/bash

# Add gravity-reth patch to Cargo.toml if not already present

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAVITY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$GRAVITY_DIR"

CARGO_TOML="gravity-sdk/Cargo.toml"

if grep -qF '[patch."https://github.com/Galxe/gravity-reth"]' "$CARGO_TOML"; then
    echo "Patch already exists. Nothing to do."
    exit 0
fi

echo "" >> "$CARGO_TOML"
echo '[patch."https://github.com/Galxe/gravity-reth"]' >> "$CARGO_TOML"
echo 'greth = { path = "/Users/xzavieryuan/workspace/op-dev/gravity-reth" }' >> "$CARGO_TOML"
echo "Patch added successfully!"

