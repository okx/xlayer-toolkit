#!/bin/bash

BASE_PORT=8547
LEADER_PORT=0
OLD_LEADER=0

# Find leader
for i in {0..2}; do
    PORT=$((BASE_PORT + i))
    IS_LEADER=$(curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_leader","params":[],"id":1}' http://localhost:$PORT | jq -r .result)
    if [ "$IS_LEADER" = "true" ]; then
        LEADER_PORT=$PORT
        OLD_LEADER=$((i+1))
        echo "conductor-$OLD_LEADER is leader (port $PORT)"
        break
    fi
done

# Transfer leadership
if [ "$LEADER_PORT" != "0" ]; then
    echo "Transferring leadership..."
    if [ -n "$1" ] && [ "$1" -ge 1 ] && [ "$1" -le 3 ]; then
        # Transfer to specific node
        TARGET_NUM=$1
        # Check if target is current leader
        if [ "$TARGET_NUM" = "$OLD_LEADER" ]; then
            echo "Error: conductor-$TARGET_NUM is already the leader"
            exit 1
        fi
        ADDR="op-conductor"
        [ "$TARGET_NUM" != "1" ] && ADDR="${ADDR}${TARGET_NUM}"
        curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_transferLeaderToServer","params":["conductor-'$TARGET_NUM'", "'$ADDR':50050"],"id":1}' http://localhost:$LEADER_PORT >/dev/null
        # Check if leader transferred to target node
        sleep 1
        NEW_LEADER=$(curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_leader","params":[],"id":1}' http://localhost:$((BASE_PORT + TARGET_NUM - 1)) | jq -r .result)
        if [ "$NEW_LEADER" = "true" ]; then
            echo "Leadership transferred: conductor-$OLD_LEADER -> conductor-$TARGET_NUM"
        else
            echo "Failed to transfer leadership from conductor-$OLD_LEADER to conductor-$TARGET_NUM"
        fi
    else
        # Auto select target node
        curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_transferLeader","params":[],"id":1}' http://localhost:$LEADER_PORT > /dev/null
        # Find new leader
        sleep 1
        echo "Checking new leader..."
        for i in {0..2}; do
            PORT=$((BASE_PORT + i))
            IS_LEADER=$(curl -s -X POST -H "Content-Type: application/json" \
                --data '{"jsonrpc":"2.0","method":"conductor_leader","params":[],"id":1}' \
                http://localhost:$PORT | jq -r .result)

            if [ "$IS_LEADER" = "true" ]; then
                echo "Leadership transferred: conductor-$OLD_LEADER -> conductor-$((i+1))"
                break
            fi
        done
    fi
fi
