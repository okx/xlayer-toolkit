#!/bin/bash
set -e
set -x

# Scheduler to run mempool rebroadcaster at regular intervals when reth is enabled.
# Default interval is set at 1 minute (60 seconds)
INTERVAL=60

SEQ_TYPE="${SEQ_TYPE:-reth}"

# Start mempool rebroadcaster scheduler for reth mode
if [ "$SEQ_TYPE" = "reth" ]; then
    echo "Starting mempool rebroadcaster scheduler with ${INTERVAL}s interval."

    while true; do
        # Run the mempool rebroadcaster
        echo "$(date): Running mempool rebroadcaster..."
        docker compose run --rm mempool-rebroadcaster
        echo "$(date): Mempool rebroadcaster completed."
        sleep "$INTERVAL"
    done
else
    echo "Mempool rebroadcaster scheduler is not in reth mode, exiting."
fi
