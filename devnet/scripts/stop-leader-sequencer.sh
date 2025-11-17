#!/bin/bash

BASE_PORT=8547
LEADER_PORT=0
OLD_LEADER=0

# Find current leader
for i in {0..2}; do
    PORT=$((BASE_PORT + i))
    IS_LEADER=$(curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"conductor_leader","params":[],"id":1}' \
        http://localhost:$PORT | jq -r .result)

    if [ "$IS_LEADER" = "true" ]; then
        LEADER_PORT=$PORT
        OLD_LEADER=$((i+1))
        echo "conductor-$OLD_LEADER is current leader (port $PORT)"
        break
    fi
done

# Stop leader's sequencer
if [ "$LEADER_PORT" != "0" ]; then
    SEQUENCER_PORT=$((9545 + OLD_LEADER -1))
    curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"admin_stopSequencer","params":[],"id":1}' http://localhost:$SEQUENCER_PORT > /dev/null
    echo "sequencer stopped, waiting for leader transfer..."

    # Wait and check for leader change every second
    echo "Waiting for leader transfer..."
    MAX_SECONDS=10
    for ((second=1; second<=MAX_SECONDS; second++)); do
        sleep 1
        NEW_LEADER=0
        for i in {0..2}; do
            PORT=$((BASE_PORT + i))
            IS_LEADER=$(curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_leader","params":[],"id":1}' http://localhost:$PORT | jq -r .result)
            if [ "$IS_LEADER" = "true" ]; then
                NEW_LEADER=$((i+1))
                if [ "$NEW_LEADER" != "$OLD_LEADER" ]; then
                    echo "Leadership transferred: conductor-$OLD_LEADER -> conductor-$NEW_LEADER in (${second}s)"
                    exit 0
                fi
            fi
        done
    done
    echo "Warning: Leader transfer not detected after $MAX_SECONDS seconds"
fi
