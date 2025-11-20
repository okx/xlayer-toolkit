#!/bin/bash
set -e

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
ENV_FILE="$(dirname "$PWD_DIR")/.env"
source "$ENV_FILE"

echo "🔧 Deploying OP-Succinct contracts..."

# Check if required environment variables are set
if [ -z "$DISPUTE_GAME_FACTORY_ADDRESS" ]; then
    echo "❌ Error: DISPUTE_GAME_FACTORY_ADDRESS is not set"
    exit 1
fi

if [ -z "$DEPLOYER_PRIVATE_KEY" ]; then
    echo "❌ Error: DEPLOYER_PRIVATE_KEY is not set"
    exit 1
fi

if [ -z "$DOCKER_NETWORK" ]; then
    echo "❌ Error: DOCKER_NETWORK is not set"
    exit 1
fi

if [ -z "$L1_RPC_URL_IN_DOCKER" ]; then
    echo "❌ Error: L1_RPC_URL_IN_DOCKER is not set"
    exit 1
fi

if [ -z "$OP_SUCCINCT_CONTRACTS_IAMGE_TAG" ]; then
    echo "❌ Error: OP_SUCCINCT_CONTRACTS_IAMGE_TAG is not set"
    exit 1
fi

echo "🚀 Deploying AccessManager..."
ACCESS_MANAGER_OUTPUT=$(docker run --rm \
    --network "$DOCKER_NETWORK" \
    -v "$PWD_DIR/op-succinct/deployment:/app/contracts/script/fp" \
    -e DISPUTE_GAME_FACTORY_ADDRESS="$DISPUTE_GAME_FACTORY_ADDRESS" \
    -w /app/contracts \
    "${OP_SUCCINCT_CONTRACTS_IAMGE_TAG}" \
    forge script script/fp/DeployAccessManager.s.sol:DeployAccessManager \
      --rpc-url "$L1_RPC_URL_IN_DOCKER" \
      --private-key "$DEPLOYER_PRIVATE_KEY" \
      --broadcast \
      --legacy \
      --gas-price 10000000000 2>&1)

ACCESS_MANAGER_ADDRESS=$(echo "$ACCESS_MANAGER_OUTPUT" | grep -oE "AccessManager deployed at: (0x[a-fA-F0-9]{40})" | sed 's/AccessManager deployed at: //')

if [ -z "$ACCESS_MANAGER_ADDRESS" ]; then
    echo "❌ Failed to deploy AccessManager"
    echo "$ACCESS_MANAGER_OUTPUT"
    exit 1
fi

echo "✅ AccessManager: $ACCESS_MANAGER_ADDRESS"

echo "🚀 Deploying SP1MockVerifier..."
VERIFIER_OUTPUT=$(docker run --rm \
    --network "$DOCKER_NETWORK" \
    -v "$PWD_DIR/op-succinct/deployment:/app/contracts/script/fp" \
    -w /app/contracts \
    "${OP_SUCCINCT_CONTRACTS_IAMGE_TAG}" \
    forge script script/fp/DeploySP1MockVerifier.s.sol:DeploySP1MockVerifier \
      --rpc-url "$L1_RPC_URL_IN_DOCKER" \
      --private-key "$DEPLOYER_PRIVATE_KEY" \
      --broadcast \
      --legacy \
      --gas-price 10000000000 2>&1)

VERIFIER_ADDRESS=$(echo "$VERIFIER_OUTPUT" | grep -oE "SP1MockVerifier deployed at: (0x[a-fA-F0-9]{40})" | sed 's/SP1MockVerifier deployed at: //')

if [ -z "$VERIFIER_ADDRESS" ]; then
    echo "❌ Failed to deploy SP1MockVerifier"
    echo "$VERIFIER_OUTPUT"
    exit 1
fi

echo "✅ SP1MockVerifier: $VERIFIER_ADDRESS"

ENV_PROPOSER_FILE="$PWD_DIR/op-succinct/.env.proposer"

if [ ! -f "$ENV_PROPOSER_FILE" ]; then
    echo "❌ Error: $ENV_PROPOSER_FILE not found"
    exit 1
fi

sed_inplace "s/^VERIFIER_ADDRESS=.*/VERIFIER_ADDRESS=$VERIFIER_ADDRESS/" "$ENV_PROPOSER_FILE"
sed_inplace "s/^ACCESS_MANAGER=.*/ACCESS_MANAGER=$ACCESS_MANAGER_ADDRESS/" "$ENV_PROPOSER_FILE"

echo "✅ Updated .env.proposer"
echo ""

upgrade_op_succinct_fdg() {
    echo ""
    echo "🔄 Upgrading OPSuccinct FDG..."
    
    local PROPOSER_ENV="$PWD_DIR/op-succinct/.env.proposer"
    if [ -f "$PROPOSER_ENV" ]; then
        source "$PROPOSER_ENV"
    else
        echo "⚠️  Warning: $PROPOSER_ENV not found"
    fi
    
    local REQUIRED_VARS=(
        "DISPUTE_GAME_FACTORY_ADDRESS"
        "TRANSACTOR"
        "DEPLOYER_PRIVATE_KEY"
        "VERIFIER_ADDRESS"
        "ACCESS_MANAGER_ADDRESS"
        "ANCHOR_STATE_REGISTRY"
        "ROLLUP_CONFIG_HASH"
        "AGGREGATION_VKEY"
        "RANGE_VKEY_COMMITMENT"
        "GAME_TYPE"
        "MAX_CHALLENGE_DURATION"
        "MAX_PROVE_DURATION"
        "CHALLENGER_BOND_WEI"
    )
    
    for var in "${REQUIRED_VARS[@]}"; do
        if [ -z "${!var}" ]; then
            echo "❌ Error: $var is not set"
            return 1
        fi
    done
    
    # Step 1: Deploy OPSuccinctFaultDisputeGame
    echo "🚀 Deploying OPSuccinctFaultDisputeGame..."
    
    DEPLOY_OUTPUT=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        -v "$PWD_DIR/op-succinct/deployment:/app/contracts/script/fp" \
        -w /app/contracts \
        "${OP_SUCCINCT_CONTRACTS_IAMGE_TAG}" \
        forge create src/fp/OPSuccinctFaultDisputeGame.sol:OPSuccinctFaultDisputeGame \
          --rpc-url "$L1_RPC_URL_IN_DOCKER" \
          --private-key "$DEPLOYER_PRIVATE_KEY" \
          --legacy \
          --json \
          --broadcast \
          --constructor-args \
            "$MAX_CHALLENGE_DURATION" \
            "$MAX_PROVE_DURATION" \
            "$DISPUTE_GAME_FACTORY_ADDRESS" \
            "$VERIFIER_ADDRESS" \
            "$ROLLUP_CONFIG_HASH" \
            "$AGGREGATION_VKEY" \
            "$RANGE_VKEY_COMMITMENT" \
            "$CHALLENGER_BOND_WEI" \
            "$ANCHOR_STATE_REGISTRY" \
            "$ACCESS_MANAGER_ADDRESS" 2>&1)
    
    NEW_GAME_ADDRESS=$(echo "$DEPLOY_OUTPUT" | jq -r '.deployedTo // empty' 2>/dev/null)
    
    if [ -z "$NEW_GAME_ADDRESS" ]; then
        echo "❌ Failed to deploy OPSuccinctFaultDisputeGame"
        echo "Deploy output: $DEPLOY_OUTPUT"
        return 1
    fi
    
    echo "✅ OPSuccinctFaultDisputeGame: $NEW_GAME_ADDRESS"
    
    # Step 2: Register via TRANSACTOR
    echo "📝 Registering game type $GAME_TYPE..."
    SET_IMPL_CALLDATA=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        "${OP_SUCCINCT_CONTRACTS_IAMGE_TAG}" \
        cast calldata 'setImplementation(uint32,address)' "$GAME_TYPE" "$NEW_GAME_ADDRESS")
    TRANSACTOR_OUTPUT=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        "${OP_SUCCINCT_CONTRACTS_IAMGE_TAG}" \
        cast send \
          --rpc-url "$L1_RPC_URL_IN_DOCKER" \
          --private-key "$DEPLOYER_PRIVATE_KEY" \
          --legacy \
          "$TRANSACTOR" \
          'CALL(address,bytes,uint256)' \
          "$DISPUTE_GAME_FACTORY_ADDRESS" \
          "$SET_IMPL_CALLDATA" \
          0 2>&1)
    
    if echo "$TRANSACTOR_OUTPUT" | grep -q "blockHash"; then
        echo "✅ Registration succeeded"
    else
        echo "❌ Registration failed"
        echo "$TRANSACTOR_OUTPUT"
        return 1
    fi
    
    # Step 3: Verify registration
    REGISTERED_IMPL=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        "${OP_SUCCINCT_CONTRACTS_IAMGE_TAG}" \
        cast call \
          --rpc-url "$L1_RPC_URL_IN_DOCKER" \
          "$DISPUTE_GAME_FACTORY_ADDRESS" \
          'gameImpls(uint32)(address)' \
          "$GAME_TYPE" | tr '[:upper:]' '[:lower:]')
    
    NEW_GAME_ADDRESS_LOWER=$(echo "$NEW_GAME_ADDRESS" | tr '[:upper:]' '[:lower:]')
    
    if [ "$REGISTERED_IMPL" = "$NEW_GAME_ADDRESS_LOWER" ]; then
        echo "✅ Verification passed"
    else
        echo "❌ Verification failed"
        echo "   Expected: $NEW_GAME_ADDRESS_LOWER"
        echo "   Got: $REGISTERED_IMPL"
        return 1
    fi
    
    # Step 4: Update Respected Game Type
    echo "📝 Setting respected game type to $GAME_TYPE..."
    ASR_OUTPUT=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        "${OP_SUCCINCT_CONTRACTS_IAMGE_TAG}" \
        cast send \
          --rpc-url "$L1_RPC_URL_IN_DOCKER" \
          --private-key "$DEPLOYER_PRIVATE_KEY" \
          --legacy \
          "$ANCHOR_STATE_REGISTRY" \
          'setRespectedGameType(uint32)' \
          "$GAME_TYPE" 2>&1)
    
    if echo "$ASR_OUTPUT" | grep -q "blockHash"; then
        echo "✅ Respected game type updated"
    else
        echo "⚠️  Warning: Failed to update respected game type"
        echo "$ASR_OUTPUT"
    fi
    
    echo ""
    echo "✅ FDG upgrade completed: $NEW_GAME_ADDRESS"
    
    sed_inplace "s/^GAME_IMPLEMENTATION=.*/GAME_IMPLEMENTATION=$NEW_GAME_ADDRESS/" "$PROPOSER_ENV"
    echo "✅ Updated .env.proposer"
}

# Upgrade FDG if enabled
if [ "${OP_SUCCINCT_UPGRADE_FDG:-false}" = "true" ]; then
    upgrade_op_succinct_fdg
fi

