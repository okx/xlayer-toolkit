#!/usr/bin/env bash
# Populate local third-party artifacts required by the benchmark / cross-check scripts:
#   1. Git dependencies under lib/ (forge-std + vendored Poseidon2 comparison libraries)
#   2. Powers-of-Tau ceremony file at bench/circom/pot12.ptau (Circom Groth16 benchmarks)
#
# Idempotent: skips each item that is already present. Safe to re-run.
#
# Usage: bash scripts/setup-libs.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$ROOT_DIR/lib"
mkdir -p "$LIB_DIR"

# ── 1. Git dependencies ──
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

# ── 2. Powers-of-Tau file (Circom Groth16 benchmarks only) ──
PTAU_PATH="$ROOT_DIR/bench/circom/pot12.ptau"
PTAU_URL="https://hermez.s3-eu-west-1.amazonaws.com/powersOfTau28_hez_final_12.ptau"

if [ -f "$PTAU_PATH" ]; then
  echo "[setup-libs] pot12.ptau: present, skipping"
else
  echo "[setup-libs] pot12.ptau: downloading from hermez.s3 (~4.6 MB)"
  mkdir -p "$(dirname "$PTAU_PATH")"
  tmp="${PTAU_PATH}.tmp"
  if command -v curl >/dev/null 2>&1; then
    curl --fail --silent --show-error --location "$PTAU_URL" -o "$tmp"
  elif command -v wget >/dev/null 2>&1; then
    wget --quiet "$PTAU_URL" -O "$tmp"
  else
    echo "[setup-libs] ERROR: neither curl nor wget is available" >&2
    exit 1
  fi
  mv "$tmp" "$PTAU_PATH"
fi

echo "[setup-libs] done"
