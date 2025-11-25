#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Function to update .env.proposer and .env.challenger with values
update_env_files() {
    local PROPOSER_ENV="$PROJECT_DIR/op-succinct/.env.proposer"
    local CHALLENGER_ENV="$PROJECT_DIR/op-succinct/.env.challenger"
    
    if [ ! -f "$PROPOSER_ENV" ]; then
        echo "❌ Error: $PROPOSER_ENV not found"
        return 1
    fi
    
    echo "🔧 Updating OP-Succinct env files..."
    
    # Update .env.proposer with values from main .env
    [ -n "$DISPUTE_GAME_FACTORY_ADDRESS" ] && sed_inplace "s|^FACTORY_ADDRESS=.*|FACTORY_ADDRESS=$DISPUTE_GAME_FACTORY_ADDRESS|" "$PROPOSER_ENV"
    [ -n "$OPTIMISM_PORTAL_PROXY_ADDRESS" ] && sed_inplace "s|^OPTIMISM_PORTAL2=.*|OPTIMISM_PORTAL2=$OPTIMISM_PORTAL_PROXY_ADDRESS|" "$PROPOSER_ENV"
    [ -n "$TRANSACTOR" ] && sed_inplace "s|^TRANSACTOR_ADDRESS=.*|TRANSACTOR_ADDRESS=$TRANSACTOR|" "$PROPOSER_ENV"
    [ -n "$DEPLOYER_PRIVATE_KEY" ] && sed_inplace "s|^DEPLOYER_PRIVATE_KEY=.*|DEPLOYER_PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY|" "$PROPOSER_ENV"
    [ -n "$OP_PROPOSER_PRIVATE_KEY" ] && sed_inplace "s|^PRIVATE_KEY=.*|PRIVATE_KEY=$OP_PROPOSER_PRIVATE_KEY|" "$PROPOSER_ENV"
    
    [ -n "$L1_RPC_URL_IN_DOCKER" ] && sed_inplace "s|^L1_RPC=.*|L1_RPC=$L1_RPC_URL_IN_DOCKER|" "$PROPOSER_ENV"
    [ -n "$L1_BEACON_URL_IN_DOCKER" ] && sed_inplace "s|^L1_BEACON_RPC=.*|L1_BEACON_RPC=$L1_BEACON_URL_IN_DOCKER|" "$PROPOSER_ENV"
    [ -n "$L2_RPC_EL_URL_IN_DOCKER" ] && sed_inplace "s|^L2_RPC=.*|L2_RPC=$L2_RPC_EL_URL_IN_DOCKER|" "$PROPOSER_ENV"
    [ -n "$L2_RPC_CL_URL_IN_DOCKER" ] && sed_inplace "s|^L2_NODE_RPC=.*|L2_NODE_RPC=$L2_RPC_CL_URL_IN_DOCKER|" "$PROPOSER_ENV"
    
    # Update OP-Succinct specific settings
    [ -n "$OP_SUCCINCT_FAST_FINALITY_MODE" ] && sed_inplace "s|^FAST_FINALITY_MODE=.*|FAST_FINALITY_MODE=$OP_SUCCINCT_FAST_FINALITY_MODE|" "$PROPOSER_ENV"
    if [ -n "$OP_SUCCINCT_MOCK_MODE" ]; then
        sed_inplace "s|^MOCK_MODE=.*|MOCK_MODE=$OP_SUCCINCT_MOCK_MODE|" "$PROPOSER_ENV"
        sed_inplace "s|^OP_SUCCINCT_MOCK=.*|OP_SUCCINCT_MOCK=$OP_SUCCINCT_MOCK_MODE|" "$PROPOSER_ENV"
    fi
    
    # Read ANCHOR_STATE_REGISTRY from state.json
    local STATE_JSON="$PROJECT_DIR/config-op/state.json"
    if [ -f "$STATE_JSON" ]; then
        local ANCHOR_STATE_REGISTRY=$(jq -r '.opChainDeployments[0].AnchorStateRegistryProxy' "$STATE_JSON" 2>/dev/null)
        if [ -n "$ANCHOR_STATE_REGISTRY" ] && [ "$ANCHOR_STATE_REGISTRY" != "null" ]; then
            sed_inplace "s|^ANCHOR_STATE_REGISTRY=.*|ANCHOR_STATE_REGISTRY=$ANCHOR_STATE_REGISTRY|" "$PROPOSER_ENV"
            echo "   ANCHOR_STATE_REGISTRY: $ANCHOR_STATE_REGISTRY"
        fi
    fi
    
    # Update with deployed contract addresses
    [ -n "$VERIFIER_ADDRESS" ] && sed_inplace "s/^VERIFIER_ADDRESS=.*/VERIFIER_ADDRESS=$VERIFIER_ADDRESS/" "$PROPOSER_ENV"
    [ -n "$ACCESS_MANAGER_ADDRESS" ] && sed_inplace "s/^ACCESS_MANAGER=.*/ACCESS_MANAGER=$ACCESS_MANAGER_ADDRESS/" "$PROPOSER_ENV"
    
    # Update .env.challenger with factory address
    [ -n "$DISPUTE_GAME_FACTORY_ADDRESS" ] && sed_inplace "s|^FACTORY_ADDRESS=.*|FACTORY_ADDRESS=$DISPUTE_GAME_FACTORY_ADDRESS|" "$CHALLENGER_ENV"
    [ -n "$L1_RPC_URL_IN_DOCKER" ] && sed_inplace "s|^L1_RPC=.*|L1_RPC=$L1_RPC_URL_IN_DOCKER|" "$CHALLENGER_ENV"
    [ -n "$L2_RPC_URL_IN_DOCKER" ] && sed_inplace "s|^L2_RPC=.*|L2_RPC=$L2_RPC_URL_IN_DOCKER|" "$CHALLENGER_ENV"
    
    echo "✅ Updated OP-Succinct env files"
}

# Function to deploy AccessManager
deploy_access_manager() {
    echo "🚀 Deploying AccessManager..."
    
    local OUTPUT=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        -v "$PROJECT_DIR/op-succinct/deployment:/app/contracts/script/fp" \
        -e DISPUTE_GAME_FACTORY_ADDRESS="$DISPUTE_GAME_FACTORY_ADDRESS" \
        -w /app/contracts \
        "${OP_SUCCINCT_CONTRACTS_IMAGE_TAG}" \
        -c "forge script script/fp/DeployAccessManager.s.sol:DeployAccessManager \
          --broadcast \
          --legacy \
          --gas-price 10000000000 \
          --rpc-url $L1_RPC_URL_IN_DOCKER \
          --private-key $DEPLOYER_PRIVATE_KEY")
    
    # ACCESS_MANAGER_ADDRESS=$(echo "$OUTPUT" | grep -oE "0x[a-fA-F0-9]{40}")
    ACCESS_MANAGER_ADDRESS=$(echo "$OUTPUT" | grep -oE "AccessManager deployed at: (0x[a-fA-F0-9]{40})" | sed 's/AccessManager deployed at: //')
    
    if [ -z "$ACCESS_MANAGER_ADDRESS" ]; then
        echo "❌ Failed to deploy AccessManager"
        exit 1
    fi
    
    echo "✅ AccessManager: $ACCESS_MANAGER_ADDRESS"
}

deploy_sp1_verifier() {
    local OUTPUT
    
    # Deploy Verifier (Mock or Real based on OP_SUCCINCT_MOCK_MODE)
    if [ "${OP_SUCCINCT_MOCK_MODE:-true}" = "true" ]; then
        echo "🚀 Deploying SP1MockVerifier..."
        # Mount local deployment scripts into container
        OUTPUT=$(docker run --rm \
            --network "$DOCKER_NETWORK" \
            --entrypoint sh \
            -v "$PWD_DIR/op-succinct/deployment:/app/contracts/script/fp" \
            -w /app/contracts \
            "${OP_SUCCINCT_CONTRACTS_IMAGE_TAG}" \
            -c "forge script script/fp/DeploySP1MockVerifier.s.sol:DeploySP1MockVerifier \
            --rpc-url $L1_RPC_URL_IN_DOCKER \
            --private-key $DEPLOYER_PRIVATE_KEY \
            --broadcast \
            --legacy \
            --gas-price 10000000000")

        VERIFIER_ADDRESS=$(echo "$OUTPUT" | grep -oE "0x[a-fA-F0-9]{40}")

        echo "✅ SP1MockVerifier: $VERIFIER_ADDRESS"
    else
        echo "🚀 Deploying SP1VerifierPlonk ..."
        
        OUTPUT=$(docker run --rm \
            --network "$DOCKER_NETWORK" \
            -v "$PROJECT_DIR/op-succinct/deployment:/app/contracts/script/fp" \
            -w /app/contracts \
            "${OP_SUCCINCT_CONTRACTS_IMAGE_TAG}" \
            -c "forge script script/fp/DeployRealVerifierPlonk.s.sol:DeployRealVerifierPlonk \
            --rpc-url $L1_RPC_URL_IN_DOCKER \
            --private-key $DEPLOYER_PRIVATE_KEY \
            --broadcast \
            --gas-price 10000000000")
        
        echo "OUTPUT: $OUTPUT"
        VERIFIER_ADDRESS=$(echo "$OUTPUT" | grep -oE "0x[a-fA-F0-9]{40}" | head -1)

        echo "✅ SP1VerifierPlonk: $VERIFIER_ADDRESS"
    fi

    if [ -z "$VERIFIER_ADDRESS" ]; then
        echo "❌ Failed to deploy SP1 Verifier"
        echo "Output: $OUTPUT"
        exit 1
    fi
}

# Function to check required environment variables
check_required_env_vars() {
    local REQUIRED_VARS=(
        "DISPUTE_GAME_FACTORY_ADDRESS"
        "DEPLOYER_PRIVATE_KEY"
        "DOCKER_NETWORK"
        "L1_RPC_URL_IN_DOCKER"
        "OP_SUCCINCT_CONTRACTS_IMAGE_TAG"
    )

    for var in "${REQUIRED_VARS[@]}"; do
        if [ -z "${!var}" ]; then
            echo "❌ Error: $var is not set"
            return 1
        fi
    done

    return 0
}

# Function to setup OP-Succinct config directories
setup_op_succinct_configs() {
    local configs_dir="$PROJECT_DIR/op-succinct/configs"
    
    echo "📁 Setting up OP-Succinct config directories..."
    
    # Create config directories
    mkdir -p "$configs_dir/L1"
    mkdir -p "$configs_dir/L2"
    
    # Copy L1 genesis config and L2 rollup config
    if [ -f "$PROJECT_DIR/l1-geth/execution/genesis.json" ] && [ -f "$PROJECT_DIR/config-op/rollup.json" ]; then
        cp "$PROJECT_DIR/l1-geth/execution/genesis.json" "$configs_dir/L1/1337.json"
        echo "   ✅ Copied L1 genesis config to $configs_dir/L1/1337.json"
    else
        echo "   ⚠️  L1 genesis.json not found at $PROJECT_DIR/l1-geth/execution/genesis.json"
        echo "   ⚠️  VKey generation may fail without L1 config"
    fi
}

# Function to configure Real mode settings and VKeys
configure_real_mode() {
    echo ""
    echo "🔍 Configuring Real mode..."
    
    # Always generate VKeys
    echo "🔄 Generating VKeys..."
    
    "$SCRIPTS_DIR/generate-vkeys.sh" || {
        echo "❌ Failed to generate VKeys"
        exit 1
    }
    
    # Reload environment after potential VKey generation
    source "$PROPOSER_ENV"
    
    # Verify required VKeys are set
    if [ -z "$AGGREGATION_VKEY" ] || [ -z "$RANGE_VKEY_COMMITMENT" ] || [ -z "$ROLLUP_CONFIG_HASH" ]; then
        echo "❌ Required VKeys not set in .env.proposer:"
        [ -z "$AGGREGATION_VKEY" ] && echo "   - AGGREGATION_VKEY"
        [ -z "$RANGE_VKEY_COMMITMENT" ] && echo "   - RANGE_VKEY_COMMITMENT"
        [ -z "$ROLLUP_CONFIG_HASH" ] && echo "   - ROLLUP_CONFIG_HASH"
        exit 1
    fi
    
    # Check SP1 Network configuration
    if ! grep -q "^NETWORK_PRIVATE_KEY=0x[a-fA-F0-9]" "$PROPOSER_ENV" 2>/dev/null; then
        echo ""
        echo "⚠️  NETWORK_PRIVATE_KEY not set"
        echo "   Real mode requires SP1 Prover Network access"
        echo ""
        echo "   To get a private key:"
        echo "   1. Visit https://platform.succinct.xyz"
        echo "   2. Create an account and fund it with PROVE tokens"
        echo "   3. Generate a private key"
        echo "   4. Add it to .env.proposer: NETWORK_PRIVATE_KEY=0x..."
        echo ""
        read -p "   Continue without NETWORK_PRIVATE_KEY? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        echo "   ✅ NETWORK_PRIVATE_KEY configured"
    fi
    
    echo ""
    echo "✅ Real mode configuration completed"
}


# Main deployment function
deploy_op_succinct_contracts() {
    echo "🔧 Deploying OP-Succinct contracts..."

    # Check environment variables
    if ! check_required_env_vars; then
        return 1
    fi

    # Setup OP-Succinct config directories
    setup_op_succinct_configs

    # Deploy contracts
    deploy_access_manager || return 1
    deploy_sp1_verifier || return 1
    update_env_files || return 1

    return 0
}

# Function: Setup OPSuccinct Fault Dispute Game (deploy and register)
setup_op_succinct_fdg() {
    echo ""
    echo "🔄 Setting up OPSuccinct FDG..."

    local PROPOSER_ENV="$PROJECT_DIR/op-succinct/.env.proposer"
    if [ -f "$PROPOSER_ENV" ]; then
        source "$PROPOSER_ENV"
    else
        echo "⚠️  Warning: $PROPOSER_ENV not found"
    fi

    if [ "${OP_SUCCINCT_MOCK_MODE:-true}" = "false" ]; then
        configure_real_mode
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
    DEPLOY_OUTPUT=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        -v "$PROJECT_DIR/op-succinct/deployment:/app/contracts/script/fp" \
        -w /app/contracts \
        "${OP_SUCCINCT_CONTRACTS_IMAGE_TAG}" \
        -c "forge create --json --broadcast --legacy \
          --rpc-url $L1_RPC_URL_IN_DOCKER \
          --private-key $DEPLOYER_PRIVATE_KEY \
          src/fp/OPSuccinctFaultDisputeGame.sol:OPSuccinctFaultDisputeGame \
          --constructor-args \
            $MAX_CHALLENGE_DURATION \
            $MAX_PROVE_DURATION \
            $DISPUTE_GAME_FACTORY_ADDRESS \
            $VERIFIER_ADDRESS \
            $ROLLUP_CONFIG_HASH \
            $AGGREGATION_VKEY \
            $RANGE_VKEY_COMMITMENT \
            $CHALLENGER_BOND_WEI \
            $ANCHOR_STATE_REGISTRY \
            $ACCESS_MANAGER_ADDRESS")

    NEW_GAME_ADDRESS=$(echo "$DEPLOY_OUTPUT" | jq -r '.deployedTo // empty' 2>/dev/null)

    if [ -z "$NEW_GAME_ADDRESS" ]; then
        echo "❌ Failed to deploy OPSuccinctFaultDisputeGame"
        return 1
    fi

    echo "✅ OPSuccinctFaultDisputeGame: $NEW_GAME_ADDRESS"

    # Step 2: Register via TRANSACTOR
    echo "📝 Registering game type $GAME_TYPE..."
    SET_IMPL_CALLDATA=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        "${OP_SUCCINCT_CONTRACTS_IMAGE_TAG}" \
        -c "cast calldata 'setImplementation(uint32,address)' $GAME_TYPE $NEW_GAME_ADDRESS")
    OUTPUT=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        "${OP_SUCCINCT_CONTRACTS_IMAGE_TAG}" \
        -c "cast send \
          --rpc-url $L1_RPC_URL_IN_DOCKER \
          --private-key $DEPLOYER_PRIVATE_KEY \
          --legacy \
          $TRANSACTOR \
          'CALL(address,bytes,uint256)' \
          $DISPUTE_GAME_FACTORY_ADDRESS \
          $SET_IMPL_CALLDATA \
          0")

    if echo "$OUTPUT" | grep -q "blockHash"; then
        echo "✅ Registration succeeded"
    else
        echo "❌ Registration failed"
        echo "$OUTPUT"
        return 1
    fi

    # Step 3: Verify registration
    REGISTERED_IMPL=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        "${OP_SUCCINCT_CONTRACTS_IMAGE_TAG}" \
        -c "cast call \
          --rpc-url $L1_RPC_URL_IN_DOCKER \
          --legacy \
          $DISPUTE_GAME_FACTORY_ADDRESS \
          'gameImpls(uint32)(address)' \
          $GAME_TYPE")

    if [ "$REGISTERED_IMPL" = "$NEW_GAME_ADDRESS" ]; then
        echo "✅ Verification passed"
    else
        echo "❌ Verification failed"
        echo "   Expected: $NEW_GAME_ADDRESS"
        echo "   Got: $REGISTERED_IMPL"
        return 1
    fi

    # Step 4: Update Respected Game Type
    echo "📝 Setting respected game type to $GAME_TYPE..."
    ASR_OUTPUT=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        "${OP_SUCCINCT_CONTRACTS_IMAGE_TAG}" \
        -c "cast send \
          --rpc-url $L1_RPC_URL_IN_DOCKER \
          --private-key $DEPLOYER_PRIVATE_KEY \
          --legacy \
          $ANCHOR_STATE_REGISTRY \
          'setRespectedGameType(uint32)' \
          $GAME_TYPE")

    if echo "$ASR_OUTPUT" | grep -q "blockHash"; then
        echo "✅ Respected game type updated"
    else
        echo "⚠️  Warning: Failed to update respected game type"
        echo "$ASR_OUTPUT"
    fi

    echo ""
    echo "✅ FDG setup completed: $NEW_GAME_ADDRESS"

    sed_inplace "s/^GAME_IMPLEMENTATION=.*/GAME_IMPLEMENTATION=$NEW_GAME_ADDRESS/" "$PROPOSER_ENV"
    echo "✅ Updated .env.proposer"

    export NEW_GAME_ADDRESS
}