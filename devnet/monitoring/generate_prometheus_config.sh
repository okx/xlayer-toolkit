#!/bin/bash

# Script to generate prometheus.yml from .env configuration
# Usage: ./generate_prometheus_config.sh

set -e

ENV_FILE=".env"
OUTPUT_FILE="prometheus.yml"

# Check if .env file exists
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env file not found!"
    echo "Please copy 'example.env' to '.env' and configure it:"
    echo "  cp example.env .env"
    exit 1
fi

# Source the .env file
set -a
source "$ENV_FILE"
set +a

# Set defaults if not specified in .env
SCRAPE_INTERVAL=${SCRAPE_INTERVAL:-15s}
EVALUATION_INTERVAL=${EVALUATION_INTERVAL:-15s}

# Function to convert comma-separated list to YAML array
format_targets() {
    local nodes="$1"
    local output=""
    
    # Split by comma and format each target
    IFS=',' read -ra ADDR <<< "$nodes"
    for addr in "${ADDR[@]}"; do
        # Trim whitespace
        addr=$(echo "$addr" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -n "$addr" ]; then
            output+="          - '$addr'\n"
        fi
    done
    
    echo -e "$output"
}

# Generate prometheus.yml content
cat > "$OUTPUT_FILE" << EOF
global:
  scrape_interval: ${SCRAPE_INTERVAL}
  evaluation_interval: ${EVALUATION_INTERVAL}

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

EOF

# Add sequencer nodes if defined
if [ -n "$SEQUENCER_NODES" ]; then
    cat >> "$OUTPUT_FILE" << EOF
  - job_name: 'sequencer-nodes'
    static_configs:
      - targets:
$(format_targets "$SEQUENCER_NODES")
        labels:
          node_type: 'sequencer'

EOF
fi

# Add RPC nodes if defined
if [ -n "$RPC_NODES" ]; then
    cat >> "$OUTPUT_FILE" << EOF
  - job_name: 'rpc-nodes'
    static_configs:
      - targets:
$(format_targets "$RPC_NODES")
        labels:
          node_type: 'rpc'

EOF
fi

echo "Generated prometheus.yml"
