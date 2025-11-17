#!/bin/bash

# Function to detect leader conductor and set ports
detect_leader() {
    echo "Detecting leader conductor..."
    
    # Check all three conductors to find the leader
    for i in 1 2 3; do
        CONDUCTOR_PORT=$((8546 + i))  # 8547, 8548, 8549
        SEQUENCER_PORT=$((9544 + i))  # 9545, 9546, 9547
        
        IS_LEADER=$(curl -sS -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"conductor_leader","params":[],"id":1}' \
            http://localhost:$CONDUCTOR_PORT 2>/dev/null | jq -r '.result' 2>/dev/null)
        
        if [ "$IS_LEADER" = "true" ]; then
            LEADER_CONDUCTOR_PORT=$CONDUCTOR_PORT
            LEADER_SEQUENCER_PORT=$SEQUENCER_PORT
            echo "Found leader: Conductor $i (conductor port: $LEADER_CONDUCTOR_PORT, sequencer port: $LEADER_SEQUENCER_PORT)"
            return 0
        else
            echo "Conductor $i (port $CONDUCTOR_PORT): not leader (result: $IS_LEADER)"
        fi
    done
    
    echo "Error: No leader conductor found!"
    exit 1
}

# Detect leader conductor and set ports
detect_leader

# 1. check connected peers
CONNECTED=$(curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"opp2p_peerStats","params":[],"id":1}' http://localhost:$LEADER_SEQUENCER_PORT | jq .result.connected)
if (( CONNECTED < 2 )); then
    echo "$CONNECTED peers connected, which is less than 2"
    echo 1
fi

# 2. try to resume conductor if it is paused
PAUSED=$(curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_paused","params":[],"id":1}' http://localhost:$LEADER_CONDUCTOR_PORT | jq -r .result)
if [ $PAUSED = "true" ]; then
    curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_resume","params":[],"id":1}' http://localhost:$LEADER_CONDUCTOR_PORT
    PAUSED=$(curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_paused","params":[],"id":1}' http://localhost:$LEADER_CONDUCTOR_PORT | jq -r .result)
    if [ $PAUSED = "true" ]; then
        echo "conductor is paused due to resume failure"
        exit 1
    fi
fi

# 3. try to start sequencer if it is stopped
ACTIVE=$(curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"admin_sequencerActive","params":[],"id":1}' http://localhost:$LEADER_CONDUCTOR_PORT | jq -r .result)
if [ $ACTIVE = "false" ]; then
    BLOCK_HASH=$(curl -sS -X POST -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}'  http://localhost:8123 | jq -r .result.hash)
    if [ -z "$BLOCK_HASH" ] || [ "$BLOCK_HASH" = "null" ]; then
        echo "Failed to get latest block hash"
        exit 1
    fi
    echo "Got latest block hash: $BLOCK_HASH"

    # 3. Start sequencer with the block hash
    curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"admin_startSequencer","params":["'"$BLOCK_HASH"'"],"id":1}' http://localhost:$LEADER_SEQUENCER_PORT
    if [ $? -ne 0 ]; then
        echo "Failed to start sequencer"
        exit 1
    fi
fi

# 4. verify sequencer is active
sleep 1
ACTIVE=$(curl -sS -X POST -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","method":"admin_sequencerActive","params":[],"id":1}' http://localhost:$LEADER_SEQUENCER_PORT | jq -r .result)
if [ "$ACTIVE" != "true" ]; then
    echo "Failed to activate sequencer"
    exit 1
fi

echo "Sequencer successfully activated"

# 5. try to add other two conductors to raft consensus cluster
SERVER_COUNT=$(curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_clusterMembership","params":[],"id":1}' http://localhost:$LEADER_CONDUCTOR_PORT  | jq '.result.servers | length')
if (( $SERVER_COUNT < 3 )); then
    curl -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_addServerAsVoter","params":["conductor-2", "op-conductor2:50050", 0],"id":1}' http://localhost:$LEADER_CONDUCTOR_PORT
    curl -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_addServerAsVoter","params":["conductor-3", "op-conductor3:50050", 0],"id":1}' http://localhost:$LEADER_CONDUCTOR_PORT
    SERVER_COUNT=$(curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_clusterMembership","params":[],"id":1}' http://localhost:$LEADER_CONDUCTOR_PORT  | jq '.result.servers | length')
    if (( $SERVER_COUNT != 3 )); then
        echo "unexpected server count, expected: 3, real: $SERVER_COUNT"
        exit 1
    fi

    echo "add 2 new voters to raft consensus cluster successfully!"
fi
