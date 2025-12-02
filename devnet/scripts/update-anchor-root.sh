#!/bin/bash
# ============================================================================
# Update Anchor Root Script
# ============================================================================
# This script updates the anchor root in the Anchor State Registry.
# 
# Workflow:
# 1. Start op-proposer to create a dispute game
# 2. Wait for game creation to complete
# 3. Stop op-proposer
# 4. Wait for challenger duration to reach TEMP_MAX_CLOCK_DURATION (by querying contract state)
# 5. Execute dispute resolution sequence:
#    - resolveClaim(0, 0)
#    - resolve()
#    - claimCredit(proposer)
#
# By completing the dispute resolution, the anchor root in Anchor State Registry
# is updated, allowing new game types to inherit this anchor root.
# ============================================================================

set -e

source .env
export GAME_TYPE=1
docker compose up -d op-proposer

echo "Waiting for op-proposer to create a game..."
GAME_CREATED=false
MAX_WAIT_TIME=600  # 10 minutes timeout
WAIT_COUNT=0

while [ "$GAME_CREATED" = false ] && [ $WAIT_COUNT -lt $MAX_WAIT_TIME ]; do
   # Check if a game was created by op-proposer
   GAME_COUNT=$(cast call --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" "gameCount()(uint256)")
   if [ "$GAME_COUNT" -gt 1 ]; then
       echo " ✅ Game created! Game count: $GAME_COUNT"
       GAME_CREATED=true
   else
       echo " ⏳ Waiting for game creation... ($WAIT_COUNT/$MAX_WAIT_TIME seconds)"
       sleep 1
       WAIT_COUNT=$((WAIT_COUNT + 1))
   fi
done

if [ "$GAME_CREATED" = false ]; then
   echo " ❌ Timeout waiting for game creation"
   exit 1
fi

echo "🛑 Stopping op-proposer..."
docker compose stop op-proposer

# Get the latest game address
LATEST_GAME_INDEX=$((GAME_COUNT - 1))
GAME_ADDRESS=$(cast call --json --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" "gameAtIndex(uint256)(uint256,uint256,address)" "$LATEST_GAME_INDEX" | jq -r '.[-1]')
echo "Game address: $GAME_ADDRESS"

# Wait until challenger duration equals TEMP_MAX_CLOCK_DURATION
echo "⏰ Waiting for challenger duration to reach ${TEMP_MAX_CLOCK_DURATION} seconds..."
while true; do
    CHALLENGER_DURATION=$(cast call --rpc-url "$L1_RPC_URL" "$GAME_ADDRESS" "getChallengerDuration(uint256)(uint64)" 0)
    if [ "$CHALLENGER_DURATION" = "${TEMP_MAX_CLOCK_DURATION}" ]; then
        echo " ✅ Challenger duration reached ${TEMP_MAX_CLOCK_DURATION} seconds"
        break
    fi
    sleep 1
done

# Resolve claim (0,0) - ignore errors
echo "1. Resolving claim (0,0)..."
cast send --private-key "$OP_CHALLENGER_PRIVATE_KEY" "$GAME_ADDRESS" "resolveClaim(uint256,uint256)" 0 0 --legacy --rpc-url "$L1_RPC_URL" --json 2>&1 || true

# Resolve game
echo "2. Resolving game..."
cast send --private-key "$OP_CHALLENGER_PRIVATE_KEY" "$GAME_ADDRESS" "resolve()" --legacy --rpc-url "$L1_RPC_URL" --json

# Wait for finality delay
sleep "$DISPUTE_GAME_FINALITY_DELAY_SECONDS"
sleep 1

# Claim credit
echo "3. Claiming credit..."
cast send --private-key "$OP_CHALLENGER_PRIVATE_KEY" "$GAME_ADDRESS" "claimCredit(address)" "$PROPOSER_ADDRESS" --legacy --rpc-url "$L1_RPC_URL" --json

echo " ✅ Dispute resolution completed!"
