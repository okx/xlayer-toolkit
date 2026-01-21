#!/bin/bash
set -e

echo " 🧹 Cleaning up Optimism test environment..."

# Create missing env files from examples
ENV_FILES=(
    ".env:example.env"
    "kailua/.env.deploy:kailua/example.env.deploy"
    "kailua/.env.proposer:kailua/example.env.proposer"
    "kailua/.env.validator:kailua/example.env.validator"
)

for env_pair in "${ENV_FILES[@]}"; do
    target="${env_pair%%:*}"
    source="${env_pair##*:}"
    if [ ! -f "$target" ] && [ -f "$source" ]; then
        echo " 🔄 Creating $target from $source..."
        cp "$source" "$target" && echo "   ✅ $target created"
    fi
done

echo " 📦 Stopping Docker containers..."
[ -f .env ] && docker compose down

echo " 🗑️  Removing generated files..."
rm -rf data
rm -rf config-op/genesis.json
rm -rf config-op/genesis-reth.json
rm -rf config-op/gen.test.reth.rpc.config.toml
rm -rf config-op/gen.test.geth.rpc.config.toml
rm -rf config-op/genesis.json.gz
rm -rf config-op/implementations.json
rm -rf config-op/intent.toml
rm -rf config-op/rollup.json
rm -rf config-op/state.json
rm -rf config-op/superchain.json
rm -rf config-op/195-*
rm -rf l1-geth/consensus/beacondata/
rm -rf l1-geth/consensus/genesis.ssz
rm -rf l1-geth/consensus/validatordata/
rm -rf l1-geth/execution/genesis.json
rm -rf l1-geth/execution/geth/
rm -rf l1-geth/execution/keystore/
rm -rf init.log
rm -rf op-succinct/configs

echo " ✅ Cleanup completed!"
