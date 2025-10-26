#!/bin/bash

# Script to run RPC compare tool in background

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Default values
LOG_FILE="compare.log"
ENV_FILE=".env"

# Check if .env exists
if [ ! -f ".env" ]; then
    echo "Creating .env from env.example..."
    if [ -f "env.example" ]; then
        cp env.example .env
        echo "Please edit .env with your configuration"
    else
        echo "Warning: env.example not found"
    fi
fi

# Run in background with nohup
nohup go run main.go -env="$ENV_FILE" -log="$LOG_FILE" > "$LOG_FILE" 2>&1 &

PID=$!
echo "RPC compare tool started in background"
echo "PID: $PID"
echo "Log file: $LOG_FILE"
echo "To stop: kill $PID"
echo "To view logs: tail -f $LOG_FILE"

