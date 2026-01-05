#!/bin/bash

set -e
set -x

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

# Get target block from command line argument or environment variable
TARGET_BLOCK="${1:-${UNWIND_TO_BLOCK:-8594000}}"

if [ -z "$TARGET_BLOCK" ]; then
    echo "Error: No target block specified"
    echo "Usage: $0 <block_number>"
    echo "   or: UNWIND_TO_BLOCK=<block_number> $0"
    exit 1
fi

echo "Unwinding to block $TARGET_BLOCK"

exec "$RETH_BINARY" stage unwind --color=never \
  --datadir="$RETH_DATA_DIR" \
  --chain="$RETH_CHAIN" \
  to-block "$TARGET_BLOCK"
