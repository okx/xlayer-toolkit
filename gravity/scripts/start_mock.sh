#!/bin/bash

# Start gravity_node in MOCK mode

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAVITY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$GRAVITY_DIR"

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is required but not installed. Please install 'jq' first."
    exit 1
fi

# Configuration file path
reth_config="./my_config/reth_config.json"

# Check if config file exists
if [ ! -f "$reth_config" ]; then
    echo "Error: Config file '$reth_config' not found."
    exit 1
fi

# Parse environment variables
while IFS= read -r key && IFS= read -r value; do
    if [ -n "$value" ] && [ "$value" != "null" ]; then
        export "${key}=${value}"
    fi
done < <(jq -r '.env_vars | to_entries[] | .key, .value' "$reth_config")

# Parse reth_args
reth_args=()
while IFS= read -r key && IFS= read -r value; do
    # Special handling for gravity disable flags
    if [[ "$key" == "gravity.disable-grevm" ]] || [[ "$key" == "gravity.disable-pipe-execution" ]]; then
        if [ "$value" == "true" ]; then
            reth_args+=( "--${key}" )  # Add flag to disable
        fi
        # If false or null, skip (don't add flag = enabled)
    elif [ -z "$value" ] || [ "$value" == "null" ]; then
        reth_args+=( "--${key}" )
    else
        reth_args+=( "--${key}=${value}" )
    fi
done < <(jq -r '.reth_args | to_entries[] | .key, .value' "$reth_config")

# Display startup information
echo "Starting gravity_node in MOCK mode..."
echo "MOCK_CONSENSUS=$MOCK_CONSENSUS"
echo "MOCK_SET_ORDERED_INTERVAL_MS=$MOCK_SET_ORDERED_INTERVAL_MS"
echo "MOCK_MAX_BLOCK_SIZE=$MOCK_MAX_BLOCK_SIZE"

# Display optimization status
disable_grevm=$(jq -r '.reth_args."gravity.disable-grevm" // false' "$reth_config")
disable_pipe=$(jq -r '.reth_args."gravity.disable-pipe-execution" // false' "$reth_config")
echo "Grevm: $([ "$disable_grevm" == "true" ] && echo "DISABLED" || echo "ENABLED")"
echo "Pipeline: $([ "$disable_pipe" == "true" ] && echo "DISABLED" || echo "ENABLED")"
echo ""

export RUST_BACKTRACE=1

# Start node in background
nohup ./gravity-sdk/target/release/gravity_node node "${reth_args[@]}" > gravity_node.out 2>&1 &
echo "gravity_node started in background (PID: $!)"
echo "Logs are written to: gravity_node.out"

