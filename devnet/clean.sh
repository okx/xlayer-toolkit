#!/bin/bash
set -e

echo " 🧹 Cleaning up Optimism test environment..."

echo " 📦 Stopping Docker containers..."
[ -f .env ] && docker compose down

echo " 🔄 Syncing .env from example.env..."
[ -f example.env ] && cp example.env .env && echo "   ✅ .env synced from example.env"

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
rm -rf init.log

echo " ✅ Cleanup completed!"
