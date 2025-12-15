#!/bin/bash

set -e

# Load environment variables from .env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/geth.env}"

if [ -f "$ENV_FILE" ]; then
    echo "Loading configuration from $ENV_FILE"
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "Warning: $ENV_FILE not found, using default values"
fi

# Set default values if not provided in .env
GETH_BINARY="${GETH_BINARY:-geth}"
GETH_DATA_DIR="${GETH_DATA_DIR:-./geth-data}"
GETH_JWT_SECRET="${GETH_JWT_SECRET:-./jwt.txt}"
GETH_HTTP_PORT="${GETH_HTTP_PORT:-9123}"
GETH_WS_PORT="${GETH_WS_PORT:-9124}"
GETH_AUTHRPC_PORT="${GETH_AUTHRPC_PORT:-8553}"
GETH_P2P_PORT="${GETH_P2P_PORT:-50505}"
GETH_VERBOSITY="${GETH_VERBOSITY:-4}"
GETH_HTTP_API="${GETH_HTTP_API:-web3,debug,eth,txpool,net,miner,admin}"
GETH_WS_API="${GETH_WS_API:-web3,debug,eth,txpool,net}"
GETH_TXPOOL_ACCOUNTSLOTS="${GETH_TXPOOL_ACCOUNTSLOTS:-100000}"
GETH_TXPOOL_GLOBALSLOTS="${GETH_TXPOOL_GLOBALSLOTS:-100000}"
GETH_TXPOOL_GLOBALQUEUE="${GETH_TXPOOL_GLOBALQUEUE:-100000}"

exec "$GETH_BINARY" \
       --verbosity "$GETH_VERBOSITY" \
       --datadir "$GETH_DATA_DIR" \
       --http \
       --http.corsdomain "*" \
       --http.port "$GETH_HTTP_PORT" \
       --http.addr 0.0.0.0 \
       --http.api "$GETH_HTTP_API" \
       --ws \
       --ws.addr 0.0.0.0 \
       --ws.port "$GETH_WS_PORT" \
       --ws.origins "*" \
       --ws.api "$GETH_WS_API" \
       --authrpc.addr 0.0.0.0 \
       --authrpc.port "$GETH_AUTHRPC_PORT" \
       --nodiscover \
       --maxpeers 0 \
       --rollup.disabletxpoolgossip \
       --port "$GETH_P2P_PORT" \
       --authrpc.jwtsecret "$GETH_JWT_SECRET" \
       --txpool.accountslots "$GETH_TXPOOL_ACCOUNTSLOTS" \
       --txpool.globalslots "$GETH_TXPOOL_GLOBALSLOTS" \
       --txpool.globalqueue "$GETH_TXPOOL_GLOBALQUEUE"
