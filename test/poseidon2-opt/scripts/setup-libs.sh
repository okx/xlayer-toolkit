#!/usr/bin/env bash
# Populate lib/ with third-party dependencies (forge-std + vendored Poseidon2 libraries
# used only for benchmarks). Idempotent: skips directories that already exist non-empty.
#
# Usage: bash scripts/setup-libs.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$ROOT_DIR/lib"
mkdir -p "$LIB_DIR"

# name | url | ref (tag or commit SHA)
DEPS=(
  "forge-std|https://github.com/foundry-rs/forge-std|v1.15.0"
  "poseidon2-evm|https://github.com/zemse/poseidon2-evm|v1.0.0"
  "poseidon2-solidity|https://github.com/V-k-h/poseidon2-solidity|f48a837ee7cdbceb36d7277198ce73cdfbaaa854"
)

for entry in "${DEPS[@]}"; do
  IFS='|' read -r name url ref <<< "$entry"
  dest="$LIB_DIR/$name"

  if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
    echo "[setup-libs] $name: present, skipping"
    continue
  fi

  echo "[setup-libs] $name: cloning $url @ $ref"
  rm -rf "$dest"
  git clone --quiet "$url" "$dest"
  git -C "$dest" checkout --quiet "$ref"
done

echo "[setup-libs] done"
