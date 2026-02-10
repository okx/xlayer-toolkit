#!/bin/bash

# Counter for number of times the script has run
count=0

echo "Starting transfer_leader.sh loop (every 120 seconds)"
echo ""

# Trap SIGINT and SIGTERM for graceful shutdown
trap 'echo -e "\n\nStopped after $count executions"; exit 0' INT TERM

while true; do
    # Increment counter
    ((count++))

    # Display current execution count with timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] Execution #$count - Running ./transfer_leader.sh"

    # Run the transfer_leader script
    ./transfer-leader.sh

    # Capture exit code
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "  WARNING: transfer_leader.sh exited with code $exit_code"
    fi

    # Wait 10 seconds before next execution
    echo "  Wait 5 seconds..."
    echo ""
    sleep 5
done