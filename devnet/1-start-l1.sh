#!/bin/bash
set -e
source .env

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker compose up -d l1-validator

sleep 3

# Extract osakaTime from genesis.json and write to .env
GENESIS_FILE="$PWD_DIR/l1-geth/execution/genesis.json"
if [ -f "$GENESIS_FILE" ]; then
    OSAKA_TIME=$(jq -r '.config.osakaTime' "$GENESIS_FILE")
    if [ -n "$OSAKA_TIME" ] && [ "$OSAKA_TIME" != "null" ]; then
        echo "📝 Extracting osakaTime from genesis.json: $OSAKA_TIME"
        if grep -q "^OSAKA_TIME=" .env; then
            sed_inplace "s/^OSAKA_TIME=.*/OSAKA_TIME=$OSAKA_TIME/" .env
        else
            echo "OSAKA_TIME=$OSAKA_TIME" >> .env
        fi
    else
        echo "⚠️  Warning: osakaTime not found in genesis.json"
    fi
else
    echo "⚠️  Warning: genesis.json not found at $GENESIS_FILE"
fi

# Calculate addresses for all actors
OP_BATCHER_ADDR=$(cast wallet a $OP_BATCHER_PRIVATE_KEY)
OP_PROPOSER_ADDR=$(cast wallet a $OP_PROPOSER_PRIVATE_KEY)
OP_CHALLENGER_ADDR=$(cast wallet a $OP_CHALLENGER_PRIVATE_KEY)

# Wait for L1 node to finish syncing
while [[ "$(cast rpc eth_syncing --rpc-url $L1_RPC_URL)" != "false" ]]; do
    echo "Waiting for node to finish syncing..."
    sleep 1
done

# Fund all actor addresses
for addr in $OP_BATCHER_ADDR $OP_PROPOSER_ADDR $OP_CHALLENGER_ADDR; do
    cast send --private-key $RICH_L1_PRIVATE_KEY --value 100ether $addr --legacy --rpc-url $L1_RPC_URL
done
