#!/bin/bash

set -e

# Load environment variables from .env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/reth.env}"

if [ -f "$ENV_FILE" ]; then
    echo "Loading configuration from $ENV_FILE"
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "Warning: $ENV_FILE not found, using default values"
fi

# Set default values if not provided in .env
RETH_BINARY="${RETH_BINARY:-op-reth}"
RETH_DATA_DIR="${RETH_DATA_DIR:-./reth-data}"
RETH_CHAIN="${RETH_CHAIN:-./rollup.json}"
RETH_JWT_SECRET="${RETH_JWT_SECRET:-./jwt.txt}"
RETH_HTTP_PORT="${RETH_HTTP_PORT:-9123}"
RETH_WS_PORT="${RETH_WS_PORT:-9124}"
RETH_AUTHRPC_PORT="${RETH_AUTHRPC_PORT:-8553}"
RETH_P2P_PORT="${RETH_P2P_PORT:-50505}"
RETH_VERBOSITY="${RETH_VERBOSITY:--vvvv}"
RETH_HTTP_API="${RETH_HTTP_API:-web3,debug,eth,txpool,net,miner,admin}"
RETH_WS_API="${RETH_WS_API:-web3,debug,eth,txpool,net}"

exec "$RETH_BINARY" node --color=never -vv \
      --datadir="$RETH_DATA_DIR" \
      --chain="$RETH_CHAIN" \
      --http \
      --http.corsdomain=* \
      --http.port="$RETH_HTTP_PORT" \
      --http.addr=0.0.0.0 \
      --http.api="$RETH_HTTP_API" \
      --ws \
      --ws.addr=0.0.0.0 \
      --ws.port="$RETH_WS_PORT" \
      --ws.origins=* \
      --ws.api="$RETH_WS_API" \
      --authrpc.addr=0.0.0.0 \
      --authrpc.port="$RETH_AUTHRPC_PORT" \
      --port "$RETH_P2P_PORT" \
      --authrpc.jwtsecret="$RETH_JWT_SECRET"
