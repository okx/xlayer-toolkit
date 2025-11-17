#!/bin/bash
set -e
source .env
docker compose up -d l1-validator

sleep 3

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
