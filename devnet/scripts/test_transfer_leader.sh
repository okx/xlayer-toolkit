#!/bin/bash

# Usage: ./test_transfer_leader.sh [max_runs]
# Repeatedly pauses the current leader's conductor+sequencer to trigger failover.

max_runs=${1:-0}  # 0 = unlimited
BASE_PORT=8547
count=0

if [ "$max_runs" -gt 0 ]; then
    echo "Starting conductor failover test (max $max_runs runs)"
else
    echo "Starting conductor failover test (unlimited runs)"
fi
echo ""

trap 'echo -e "\n\nStopped after $count executions"; exit 0' INT TERM

while true; do
    ((count++))
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] Execution #$count"

    # --- Step 1: Find current leader ---
    LEADER_PORT=0
    OLD_LEADER=0
    for i in {0..2}; do
        PORT=$((BASE_PORT + i))
        IS_LEADER=$(curl -s -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"conductor_leader","params":[],"id":1}' \
            http://localhost:$PORT 2>/dev/null | jq -r .result)
        if [ "$IS_LEADER" = "true" ]; then
            LEADER_PORT=$PORT
            OLD_LEADER=$((i+1))
            break
        fi
    done

    if [ "$LEADER_PORT" = "0" ]; then
        echo "  ERROR: No leader found"
        sleep 5
        continue
    fi

    # Map leader to container names (all using reth)
    if [ "$OLD_LEADER" = "1" ]; then
        CONDUCTOR_CONTAINER="op-conductor"
        SEQ_CONTAINER="op-reth-seq"
    else
        CONDUCTOR_CONTAINER="op-conductor${OLD_LEADER}"
        SEQ_CONTAINER="op-reth-seq${OLD_LEADER}"
    fi
    echo "  Current leader: conductor-$OLD_LEADER ($CONDUCTOR_CONTAINER + $SEQ_CONTAINER)"

    # --- Step 2: Pause leader's containers to trigger failover ---
    echo "  Pausing $CONDUCTOR_CONTAINER and $SEQ_CONTAINER..."
    docker pause "$CONDUCTOR_CONTAINER" "$SEQ_CONTAINER" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "  ERROR: Failed to pause containers"
        sleep 5
        continue
    fi

    # --- Step 3: Wait for new leader election ---
    NEW_LEADER=0
    MAX_WAIT=15
    for ((s=1; s<=MAX_WAIT; s++)); do
        sleep 0.5
        for i in {0..2}; do
            PORT=$((BASE_PORT + i))

            # Skip paused conductor
            if [ $((i+1)) = "$OLD_LEADER" ]; then
                continue
            fi

            IS_LEADER=$(curl -s -X POST -H "Content-Type: application/json" \
                --data '{"jsonrpc":"2.0","method":"conductor_leader","params":[],"id":1}' \
                http://localhost:$PORT 2>/dev/null | jq -r .result)

            if [ "$IS_LEADER" = "true" ]; then
                NEW_LEADER=$((i+1))
                echo "  ✓ Failover completed: conductor-$OLD_LEADER → conductor-$NEW_LEADER (${s}s)"
                break 2
            fi
        done
    done

    if [ "$NEW_LEADER" = "0" ]; then
        echo "  WARNING: No new leader elected after ${MAX_WAIT}s"
    else
        # Wait for new leader to build blocks before unpausing old leader
        echo "  Waiting 5s for new leader to build blocks..."
        sleep 5
    fi

    # --- Step 4: Unpause old leader's containers ---
    echo "  Unpausing $CONDUCTOR_CONTAINER and $SEQ_CONTAINER..."
    docker unpause "$CONDUCTOR_CONTAINER" "$SEQ_CONTAINER" 2>/dev/null

    # --- Wait before next iteration ---
    random_ms=$((RANDOM % 501))
    sleep_time=$(printf '10.%03d' "$random_ms")
    echo "  Waiting ${sleep_time}s before next iteration..."
    echo ""
    sleep "$sleep_time"

    # Stop if max runs reached
    if [ "$max_runs" -gt 0 ] && [ "$count" -ge "$max_runs" ]; then
        echo "Completed $max_runs runs. Exiting."
        exit 0
    fi
done
