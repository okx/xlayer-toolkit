#!/bin/bash
set -e

echo " 🧹 Cleaning up Optimism test environment..."

echo " 📦 Stopping Docker containers..."
[ -f .env ] && docker compose down

if [ ! -f .env ] && [ -f example.env ]; then
    echo " 🔄 Creating .env from example.env..."
    cp example.env .env && echo "   ✅ .env created from example.env"
fi

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

echo " 🗑️  Removing RAILGUN data..."
rm -rf railgun/deployments/*
rm -rf railgun/config/*
# Keep .env.contract file but could optionally remove it
# rm -rf railgun/.env.contract

echo " ✅ Cleanup completed!"
