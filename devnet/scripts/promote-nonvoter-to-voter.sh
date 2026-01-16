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


curl -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_addServerAsVoter","params":["conductor-3", "op-conductor3:50050", 0],"id":1}' http://localhost:$LEADER_CONDUCTOR_PORT