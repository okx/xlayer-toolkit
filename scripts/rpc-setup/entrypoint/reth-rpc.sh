#!/bin/bash

set -e

# Check if .env file exists and source it
if [ -f /.env ]; then
    source /.env
elif [ -f .env ]; then
    source .env
else
    echo "⚠️  Warning: .env file not found, using environment variables"
fi

# Build base command arguments
BASE_ARGS=(
    "--datadir=/datadir"
    "--chain=/genesis.json"
    "--config=/config.toml"
    "--http"
    "--http.corsdomain=*"
    "--http.port=8545"
    "--http.addr=0.0.0.0"
    "--http.api=web3,debug,eth,txpool,net,miner"
    "--ws"
    "--ws.addr=0.0.0.0"
    "--ws.port=7546"
    "--ws.origins=*"
    "--ws.api=debug,eth,txpool,net"
    "--disable-discovery"
    "--max-outbound-peers=0"
    "--max-inbound-peers=0"
    "--authrpc.addr=0.0.0.0"
    "--authrpc.port=8552"
    "--authrpc.jwtsecret=/jwt.txt"
    "--rollup.disable-tx-pool-gossip"
    "--bootnodes=${OP_GETH_BOOTNODE}"
)

# Add sequencer-http if SEQUENCER_HTTP_URL is set
if [ -n "${SEQUENCER_HTTP_URL}" ]; then
    BASE_ARGS+=("--rollup.sequencer-http=${SEQUENCER_HTTP_URL}")
fi

# Execute op-reth with all arguments
exec op-reth node "${BASE_ARGS[@]}"
