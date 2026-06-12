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

# Some dirs below are created by containers running as root, so the host user
# can't rm them ("Permission denied"). Delete them from inside a root container
# (the same mechanism that created them) before the plain rm -rf calls run.
# Use the locally-present op-reth image to avoid needing a registry pull.
[ -f .env ] && . ./.env 2>/dev/null || true
CLEAN_IMAGE="${OP_RETH_IMAGE_TAG:-alpine}"
docker run --rm -v "$(pwd):/w" --entrypoint sh "$CLEAN_IMAGE" -c '
  rm -rf /w/data \
         /w/l1-geth/consensus/beacondata /w/l1-geth/consensus/genesis.ssz /w/l1-geth/consensus/validatordata \
         /w/l1-geth/execution/geth /w/l1-geth/execution/keystore /w/l1-geth/execution/genesis.json \
         /w/op-succinct/configs
' 2>/dev/null || echo " ⚠️ root-owned cleanup via container skipped (will fall back to host rm)"

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
