#!/bin/bash

set -e

BASE_CONDUCTOR_PORT=8547
BASE_SEQUENCER_PORT=9545
CURRENT_LEADER=0
UPGRADED_SEQUENCER=0

# Function to check if a conductor is leader
check_leader() {
    local conductor_id=$1
    local port=$((BASE_CONDUCTOR_PORT + conductor_id - 1))
    curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"conductor_leader","params":[],"id":1}' \
        http://localhost:$port | jq -r .result
}

# Function to stop containers
stop_containers() {
    local sequencer_id=$1
    echo "Stopping containers for sequencer-$sequencer_id..."

    # Handle sequencer 1 (no suffix) vs others (with suffix)
    if [ "$sequencer_id" = "1" ]; then
        docker stop op-seq op-geth-seq 2>/dev/null || true
        echo "Containers stopped: op-seq, op-geth-seq"
    else
        docker stop op-seq$sequencer_id op-geth-seq$sequencer_id 2>/dev/null || true
        echo "Containers stopped: op-seq$sequencer_id, op-geth-seq$sequencer_id"
    fi
}

# Function to start containers
start_containers() {
    local sequencer_id=$1
    echo "Starting containers for sequencer-$sequencer_id..."

    # Handle sequencer 1 (no suffix) vs others (with suffix)
    if [ "$sequencer_id" = "1" ]; then
        docker start op-seq op-geth-seq 2>/dev/null || true
        echo "Containers started: op-seq, op-geth-seq"
    else
        docker start op-seq$sequencer_id op-geth-seq$sequencer_id 2>/dev/null || true
        echo "Containers started: op-seq$sequencer_id, op-geth-seq$sequencer_id"
    fi
}

# Function to wait for service to be ready
wait_for_service() {
    local port=$1
    local service_name=$2
    local max_attempts=30
    local attempt=0

    echo "Waiting for $service_name to be ready on port $port..."
    while [ $attempt -lt $max_attempts ]; do
        if curl -s http://localhost:$port > /dev/null 2>&1; then
            echo "$service_name is ready"
            return 0
        fi
        sleep 1
        ((attempt++))
    done
    echo "Warning: $service_name not ready after $max_attempts seconds"
    return 1
}

# Function to find current leader
find_current_leader() {
    for i in {0..2}; do
        local port=$((BASE_CONDUCTOR_PORT + i))
        local is_leader=$(check_leader $((i+1)))

        if [ "$is_leader" = "true" ]; then
            CURRENT_LEADER=$((i+1))
            echo "conductor-$CURRENT_LEADER is current leader (port $port)"
            return 0
        fi
    done
    echo "No leader found!"
    return 1
}

# Function to extract block info from sequencer logs
extract_last_block_info() {
    local sequencer_id=$1

    # Handle sequencer 1 (no suffix) vs others (with suffix)
    local container_name
    if [ "$sequencer_id" = "1" ]; then
        container_name="op-seq"
    else
        container_name="op-seq$sequencer_id"
    fi

    echo "Extracting last block info from $container_name..." >&2

    # Get the last "Sequencer inserted block" log entry
    local last_block_log=$(docker logs $container_name 2>&1 | grep "Sequencer inserted block" | tail -1)

    if [ -z "$last_block_log" ]; then
        echo "❌ No 'Sequencer inserted block' log found in $container_name" >&2
        return 1
    fi

    echo "Last block log: $last_block_log" >&2

    # Extract block hash and number using regex
    if [[ $last_block_log =~ block=([^[:space:]]+) ]]; then
        local block_info="${BASH_REMATCH[1]}"
        echo "Block info: $block_info" >&2

        # Split block hash and number (format: hash:number)
        if [[ $block_info =~ ^([^:]+):([0-9]+)$ ]]; then
            local block_hash="${BASH_REMATCH[1]}"
            local block_number="${BASH_REMATCH[2]}"
            echo "Extracted - Block Hash: $block_hash, Block Number: $block_number" >&2
            echo "$block_hash:$block_number"
            return 0
        else
            echo "❌ Failed to parse block info format: $block_info" >&2
            return 1
        fi
    else
        echo "❌ Failed to extract block info from log: $last_block_log" >&2
        return 1
    fi
}

# Function to check if new leader continues from previous block
check_block_continuity() {
    local prev_sequencer_id=$1
    local new_sequencer_id=$2
    local prev_block_info=$3

    echo "Checking block continuity from sequencer-$prev_sequencer_id to sequencer-$new_sequencer_id..."
    echo "Previous block info: $prev_block_info"

    # Parse previous block info
    local prev_block_hash=$(echo "$prev_block_info" | cut -d':' -f1)
    local prev_block_number=$(echo "$prev_block_info" | cut -d':' -f2)

    echo "Looking for block with parent=$prev_block_hash:$prev_block_number in sequencer-$new_sequencer_id..."

    # Check if new sequencer has a block with the previous block as parent
    local container_name
    if [ "$new_sequencer_id" = "1" ]; then
        container_name="op-seq"
    else
        container_name="op-seq$new_sequencer_id"
    fi
    local continuity_log=$(docker logs $container_name 2>&1 | grep "Sequencer inserted block" | grep "parent=$prev_block_hash:$prev_block_number" | tail -1)

    if [ -n "$continuity_log" ]; then
        echo "✅ Block continuity verified!"
        echo "Continuity log: $continuity_log"

        # Extract the new block info
        if [[ $continuity_log =~ block=([^[:space:]]+) ]]; then
            local new_block_info="${BASH_REMATCH[1]}"
            echo "New block info: $new_block_info"
            return 0
        fi
    else
        echo "❌ Block continuity check failed - no block found with parent=$prev_block_hash:$prev_block_number"
        return 1
    fi
}

# Function to transfer leadership
transfer_leadership() {
    local from_conductor=$1
    local to_conductor=$2
    local from_port=$((BASE_CONDUCTOR_PORT + from_conductor - 1))

    # Build target conductor address
    local target_addr="op-conductor"
    [ "$to_conductor" != "1" ] && target_addr="${target_addr}${to_conductor}"
    target_addr="${target_addr}:50050"

    echo "Transferring leadership from conductor-$from_conductor to conductor-$to_conductor..."
    curl -s -X POST -H "Content-Type: application/json" \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"conductor_transferLeaderToServer\",\"params\":[\"conductor-$to_conductor\", \"$target_addr\"],\"id\":1}" \
        http://localhost:$from_port > /dev/null
    echo "Leadership transfer command sent"
}

echo "=== Starting Gray Upgrade Simulation ==="

# Step 1: Find current leader
echo "Step 1: Finding current leader..."
if ! find_current_leader; then
    echo "Error: No leader found, exiting"
    exit 1
fi

# Step 2: Select a follower sequencer for upgrade
echo "Step 2: Selecting a follower sequencer for upgrade..."
# Find a follower (non-leader) sequencer to upgrade
UPGRADED_SEQUENCER=0
for i in {1..3}; do
    if [ "$i" != "$CURRENT_LEADER" ]; then
        UPGRADED_SEQUENCER=$i
        echo "Selected sequencer-$UPGRADED_SEQUENCER for upgrade (current leader is sequencer-$CURRENT_LEADER)"
        break
    fi
done

if [ "$UPGRADED_SEQUENCER" -eq 0 ]; then
    echo "Error: No follower sequencer found for upgrade"
    exit 1
fi

# Step 3: Stop containers for the selected follower sequencer
echo "Step 3: Stopping containers for sequencer-$UPGRADED_SEQUENCER (simulating shutdown for upgrade)..."
stop_containers $UPGRADED_SEQUENCER

# Step 4: Wait 10 seconds (simulating upgrade time)
echo "Step 4: Waiting 10 seconds for upgrade simulation..."
sleep 10

# Step 5: Restart containers
echo "Step 5: Restarting containers for sequencer-$UPGRADED_SEQUENCER (simulating post-upgrade restart)..."
start_containers $UPGRADED_SEQUENCER

# Step 6: Wait for services to be ready
echo "Step 6: Waiting for services to be ready..."
wait_for_service $((BASE_SEQUENCER_PORT + UPGRADED_SEQUENCER - 1)) "op-seq$UPGRADED_SEQUENCER"
wait_for_service $((BASE_CONDUCTOR_PORT + UPGRADED_SEQUENCER - 1)) "op-conductor$UPGRADED_SEQUENCER"

# Step 7: Verify the upgraded sequencer is inactive
echo "Step 7: Verifying upgraded sequencer is inactive..."
sleep 5  # Give it time to sync
is_leader_after_restart=$(check_leader $UPGRADED_SEQUENCER)

if [ "$is_leader_after_restart" = "false" ]; then
    echo "✅ Verified: Upgraded sequencer-$UPGRADED_SEQUENCER is inactive (not leader)"
else
    echo "❌ Error: Upgraded sequencer-$UPGRADED_SEQUENCER is unexpectedly still leader"
    exit 1
fi
# Step 8: Wait for the upgraded sequencer to sync with latest blocks
echo "Step 8: Waiting 30 seconds for upgraded sequencer to sync with latest blocks..."
sleep 30

# Step 9: Find current leader and transfer leadership
echo "Step 9: Finding current leader and transferring leadership to upgraded sequencer..."
if ! find_current_leader; then
    echo "Error: No current leader found for transfer"
    exit 1
fi

if [ "$CURRENT_LEADER" = "$UPGRADED_SEQUENCER" ]; then
    echo "✅ Upgraded sequencer-$UPGRADED_SEQUENCER is already the leader, no transfer needed"
else
    echo "Current leader is conductor-$CURRENT_LEADER, transferring to conductor-$UPGRADED_SEQUENCER"

    # Transfer leadership to the upgraded sequencer
    transfer_leadership $CURRENT_LEADER $UPGRADED_SEQUENCER

    # Verify the transfer was successful
    sleep 2
    echo "Verifying leadership transfer..."
    is_transfer_successful=$(check_leader $UPGRADED_SEQUENCER)
    if [ "$is_transfer_successful" = "true" ]; then
        echo "✅ Leadership transfer successful: conductor-$CURRENT_LEADER -> conductor-$UPGRADED_SEQUENCER"

        # Extract block info from previous leader AFTER transfer is confirmed
        echo "Extracting block info from previous leader (sequencer-$CURRENT_LEADER) after final transfer..."
        if ! CURRENT_BLOCK_INFO=$(extract_last_block_info $CURRENT_LEADER); then
            echo "Warning: Could not extract block info from sequencer-$CURRENT_LEADER, continuing without continuity check"
            CURRENT_BLOCK_INFO=""
        fi

        # Check block continuity if we have current block info
        if [ -n "$CURRENT_BLOCK_INFO" ]; then
            echo "Checking block continuity after leadership transfer..."
            sleep 3  # Give some time for upgraded sequencer to produce blocks
            if check_block_continuity $CURRENT_LEADER $UPGRADED_SEQUENCER "$CURRENT_BLOCK_INFO"; then
                echo "✅ Block continuity verified after leadership transfer"
            else
                echo "⚠️  Block continuity check failed after transfer, but upgrade simulation continues"
            fi
        fi
    else
        echo "❌ Leadership transfer failed, trying to find current leader..."
        if find_current_leader; then
            echo "Current leader is now conductor-$CURRENT_LEADER"
        else
            echo "Error: No leader found after transfer attempt"
            exit 1
        fi
    fi
fi

# Step 10: Final verification
echo "Step 10: Final verification of upgraded sequencer leadership..."
sleep 1

is_leader_final=$(check_leader $UPGRADED_SEQUENCER)
if [ "$is_leader_final" = "true" ]; then
    echo "✅ SUCCESS: Upgraded sequencer-$UPGRADED_SEQUENCER is now the leader!"
    echo "=== Gray Upgrade Simulation Completed Successfully ==="
else
    echo "❌ FAILED: Upgraded sequencer-$UPGRADED_SEQUENCER did not become leader"
    echo "Final leader status: $is_leader_final"
    exit 1
fi
