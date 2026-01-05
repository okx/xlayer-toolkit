#!/bin/bash

set -e
set -x

# Load environment variables from .env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/replayor.env}"

if [ -f "$ENV_FILE" ]; then
    echo "Loading configuration from $ENV_FILE"
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "Warning: $ENV_FILE not found, using default values"
fi

# Set default values if not provided in .env
REPLAYOR_BINARY="${REPLAYOR_BINARY:-replayor}"
ENGINE_API_SECRET="${ENGINE_API_SECRET:-0c00f14247582fcd3c837311148cda1f56e7c2caa42fb1ba8a3cc7843603846e}"
ENGINE_API_URL="${ENGINE_API_URL:-http://127.0.0.1:8553}"
EXECUTION_URL="${EXECUTION_URL:-http://127.0.0.1:9123}"
SOURCE_NODE_URL="${SOURCE_NODE_URL:-http://127.0.0.1:8123}"
STRATEGY="${STRATEGY:-replay}"
ROLLUP_CONFIG_PATH="${ROLLUP_CONFIG_PATH:-./rollup.json}"
DISK_PATH="${DISK_PATH:-./result}"
STORAGE_TYPE="${STORAGE_TYPE:-disk}"
BLOCK_COUNT="${BLOCK_COUNT:-1}"

echo "Starting Replayor in $(pwd)"
echo "$CONTINUOUS_MODE"
if [ "$CONTINUOUS_MODE" = "true" ]; then
  exec "$REPLAYOR_BINARY" \
    --engine-api-secret="$ENGINE_API_SECRET" \
    --engine-api-url="$ENGINE_API_URL" \
    --execution-url="$EXECUTION_URL" \
    --source-node-url="$SOURCE_NODE_URL" \
    --strategy="$STRATEGY" \
    --rollup-config-path="$ROLLUP_CONFIG_PATH" \
    --disk-path="$DISK_PATH" \
    --storage-type="$STORAGE_TYPE" \
    --log.level warn \
    --continuous
else
  exec "$REPLAYOR_BINARY" \
    --engine-api-secret="$ENGINE_API_SECRET" \
    --engine-api-url="$ENGINE_API_URL" \
    --execution-url="$EXECUTION_URL" \
    --source-node-url="$SOURCE_NODE_URL" \
    --strategy="$STRATEGY" \
    --rollup-config-path="$ROLLUP_CONFIG_PATH" \
    --disk-path="$DISK_PATH" \
    --storage-type="$STORAGE_TYPE" \
    --log.level warn \
    --block-count="$BLOCK_COUNT"
fi

