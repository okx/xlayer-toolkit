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

echo "Initializing Reth database at $RETH_DATA_DIR with chain config $RETH_CHAIN"

exec "$RETH_BINARY" init \
  --datadir="$RETH_DATA_DIR" \
  --chain="$RETH_CHAIN"