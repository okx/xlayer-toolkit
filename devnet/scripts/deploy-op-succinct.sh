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
ENV_FILE="$PWD_DIR/.env"
source "$ENV_FILE"

deploy_op_succinct_contracts() {
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
# Mount local deployment scripts into container
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

# Deploy Verifier (Mock or Real based on OP_SUCCINCT_MOCK_MODE)
if [ "${OP_SUCCINCT_MOCK_MODE:-true}" = "true" ]; then
    echo "🚀 Deploying SP1MockVerifier..."
    # Mount local deployment scripts into container
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
else
    echo "🚀 Deploying SP1VerifierPlonk (v5.0.0)..."
    
    # Deploy using forge create
    # Note: Contract class name is SP1Verifier, not SP1VerifierPlonk
    VERIFIER_OUTPUT=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        -w /app/contracts \
        "${OP_SUCCINCT_CONTRACTS_IAMGE_TAG}" \
        forge create lib/sp1-contracts/contracts/src/v5.0.0/SP1VerifierPlonk.sol:SP1Verifier \
          --rpc-url "$L1_RPC_URL_IN_DOCKER" \
          --private-key "$DEPLOYER_PRIVATE_KEY" \
          --broadcast \
          --legacy 2>&1)
    
    VERIFIER_ADDRESS=$(echo "$VERIFIER_OUTPUT" | grep -oE "Deployed to: (0x[a-fA-F0-9]{40})" | sed 's/Deployed to: //')
    
    # Fallback: should not be needed, but kept for safety
    if [ -z "$VERIFIER_ADDRESS" ]; then
        echo "⚠️  First attempt failed, retrying..."
        echo "Debug output:"
        echo "$VERIFIER_OUTPUT" | head -20
        exit 1
    fi
    
    if [ -z "$VERIFIER_ADDRESS" ]; then
        echo "❌ Failed to deploy SP1VerifierPlonk"
        echo "Output: $VERIFIER_OUTPUT"
        exit 1
    fi
    
    # Verify the VERIFIER_HASH matches v5.0.0
    VERIFIER_HASH=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        "${OP_SUCCINCT_CONTRACTS_IAMGE_TAG}" \
        cast call \
          --rpc-url "$L1_RPC_URL_IN_DOCKER" \
          "$VERIFIER_ADDRESS" \
          'VERIFIER_HASH()(bytes32)' 2>/dev/null || echo "")
    
    EXPECTED_HASH="0xd4e8ecd2357dd882209800acd6abb443d231cf287d77ba62b732ce937c8b56e7"
    if [ "$VERIFIER_HASH" = "$EXPECTED_HASH" ]; then
        echo "✅ SP1VerifierPlonk v5.0.0: $VERIFIER_ADDRESS"
        echo "   VERIFIER_HASH: $VERIFIER_HASH ✓"
    else
        echo "⚠️  SP1VerifierPlonk deployed: $VERIFIER_ADDRESS"
        echo "   VERIFIER_HASH: $VERIFIER_HASH (expected: $EXPECTED_HASH)"
    fi
fi

ENV_PROPOSER_FILE="$PWD_DIR/op-succinct/.env.proposer"

if [ ! -f "$ENV_PROPOSER_FILE" ]; then
    echo "❌ Error: $ENV_PROPOSER_FILE not found"
    exit 1
fi

sed_inplace "s/^VERIFIER_ADDRESS=.*/VERIFIER_ADDRESS=$VERIFIER_ADDRESS/" "$ENV_PROPOSER_FILE"
sed_inplace "s/^ACCESS_MANAGER=.*/ACCESS_MANAGER=$ACCESS_MANAGER_ADDRESS/" "$ENV_PROPOSER_FILE"

# Update FACTORY_ADDRESS from main .env
if [ -n "$DISPUTE_GAME_FACTORY_ADDRESS" ]; then
    sed_inplace "s/^FACTORY_ADDRESS=.*/FACTORY_ADDRESS=$DISPUTE_GAME_FACTORY_ADDRESS/" "$ENV_PROPOSER_FILE"
    echo "   ✅ FACTORY_ADDRESS: $DISPUTE_GAME_FACTORY_ADDRESS"
fi

# Query and update ANCHOR_STATE_REGISTRY
if [ -n "$OPTIMISM_PORTAL_PROXY_ADDRESS" ]; then
    echo "🔍 Querying AnchorStateRegistry from Portal..."
    ANCHOR_STATE_REGISTRY=$(docker run --rm --network "$DOCKER_NETWORK" \
        "${OP_SUCCINCT_CONTRACTS_IAMGE_TAG}" \
        cast call --rpc-url "$L1_RPC_URL_IN_DOCKER" \
        "$OPTIMISM_PORTAL_PROXY_ADDRESS" 'anchorStateRegistry()(address)' 2>/dev/null)
    
    if [ -n "$ANCHOR_STATE_REGISTRY" ] && [ "$ANCHOR_STATE_REGISTRY" != "0x0000000000000000000000000000000000000000" ]; then
        echo "   ✅ AnchorStateRegistry: $ANCHOR_STATE_REGISTRY"
        sed_inplace "s/^ANCHOR_STATE_REGISTRY=.*/ANCHOR_STATE_REGISTRY=$ANCHOR_STATE_REGISTRY/" "$ENV_PROPOSER_FILE"
    else
        echo "   ⚠️  Failed to query AnchorStateRegistry"
    fi
fi

# Update MOCK_MODE setting
if [ "${OP_SUCCINCT_MOCK_MODE:-true}" = "true" ]; then
    sed_inplace "s/^MOCK_MODE=.*/MOCK_MODE=true/" "$ENV_PROPOSER_FILE"
else
    sed_inplace "s/^MOCK_MODE=.*/MOCK_MODE=false/" "$ENV_PROPOSER_FILE"
    
    # For Real mode, verify and generate VKey configuration
    echo ""
    echo "🔍 Configuring Real mode..."
    
    # Check if AGGREGATION_VKEY is set
    if ! grep -q "^AGGREGATION_VKEY=0x[a-fA-F0-9]" "$ENV_PROPOSER_FILE" 2>/dev/null; then
        echo "⚠️  AGGREGATION_VKEY not found in .env.proposer"
        echo "   Attempting to generate VKeys..."
        
        # Try to generate VKeys automatically
        if [ -n "$OP_SUCCINCT_DIRECTORY" ] && [ -d "$OP_SUCCINCT_DIRECTORY" ]; then
            VKEY_SCRIPT="$(dirname "$PWD_DIR")/scripts/generate-vkeys.sh"
            if [ -f "$VKEY_SCRIPT" ]; then
                bash "$VKEY_SCRIPT" || {
                    echo "❌ Failed to generate VKeys"
                    echo "   Please generate manually:"
                    echo "   cd $OP_SUCCINCT_DIRECTORY && cargo run --bin config --release"
                    exit 1
                }
            else
                echo "❌ generate-vkeys.sh not found"
                echo "   Please generate VKeys manually:"
                echo "   cd $OP_SUCCINCT_DIRECTORY && cargo run --bin config --release"
                exit 1
            fi
        else
            echo "❌ OP_SUCCINCT_DIRECTORY not set or invalid"
            exit 1
        fi
    else
        AGGREGATION_VKEY=$(grep "^AGGREGATION_VKEY=" "$ENV_PROPOSER_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
        RANGE_VKEY_COMMITMENT=$(grep "^RANGE_VKEY_COMMITMENT=" "$ENV_PROPOSER_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
        ROLLUP_CONFIG_HASH=$(grep "^ROLLUP_CONFIG_HASH=" "$ENV_PROPOSER_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
        
        echo "   ✅ VKeys found in configuration"
        echo "      AGGREGATION_VKEY: $AGGREGATION_VKEY"
        
        # Verify it's not a placeholder
        if echo "$AGGREGATION_VKEY" | grep -qE "^0x(abcdef|000000|111111|00{62,})"; then
            echo "   ⚠️  Looks like a placeholder! Regenerating..."
            VKEY_SCRIPT="$(dirname "$PWD_DIR")/scripts/generate-vkeys.sh"
            if [ -f "$VKEY_SCRIPT" ]; then
                bash "$VKEY_SCRIPT" || {
                    echo "❌ Failed to generate VKeys"
                    exit 1
                }
            fi
        fi
    fi
    
    # Reload environment after potential VKey generation
    source "$ENV_PROPOSER_FILE"
    
    # Verify required VKeys are set
    if [ -z "$AGGREGATION_VKEY" ] || [ -z "$RANGE_VKEY_COMMITMENT" ] || [ -z "$ROLLUP_CONFIG_HASH" ]; then
        echo "❌ Required VKeys not set in .env.proposer:"
        [ -z "$AGGREGATION_VKEY" ] && echo "   - AGGREGATION_VKEY"
        [ -z "$RANGE_VKEY_COMMITMENT" ] && echo "   - RANGE_VKEY_COMMITMENT"
        [ -z "$ROLLUP_CONFIG_HASH" ] && echo "   - ROLLUP_CONFIG_HASH"
        exit 1
    fi
    
    # Check SP1 Network configuration
    if ! grep -q "^NETWORK_PRIVATE_KEY=0x[a-fA-F0-9]" "$ENV_PROPOSER_FILE" 2>/dev/null; then
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
    echo "✅ Real mode configuration verified"
fi

echo ""
echo "✅ Updated .env.proposer"
echo ""
}

setup_op_succinct_fdg() {
    if [ "${OP_SUCCINCT_UPGRADE_FDG:-false}" = "true" ]; then
        upgrade_op_succinct_fdg
    else
        echo "⏭️  Skipping FDG upgrade (OP_SUCCINCT_UPGRADE_FDG not set to true)"
    fi
}

upgrade_op_succinct_fdg() {
    echo ""
    echo "🔄 Upgrading OPSuccinct FDG..."
    
    local PROPOSER_ENV="$PWD_DIR/op-succinct/.env.proposer"
    if [ -f "$PROPOSER_ENV" ]; then
        source "$PROPOSER_ENV"
    else
        echo "⚠️  Warning: $PROPOSER_ENV not found"
    fi

    # Ensure ANCHOR_STATE_REGISTRY is set
    if [ -z "$ANCHOR_STATE_REGISTRY" ]; then
        echo "🔍 Querying AnchorStateRegistry from Portal..."
        if [ -n "$OPTIMISM_PORTAL_PROXY_ADDRESS" ]; then
            ANCHOR_STATE_REGISTRY=$(docker run --rm --network "$DOCKER_NETWORK" \
                "${OP_SUCCINCT_CONTRACTS_IAMGE_TAG}" \
                cast call --rpc-url "$L1_RPC_URL_IN_DOCKER" \
                "$OPTIMISM_PORTAL_PROXY_ADDRESS" 'anchorStateRegistry()(address)')
            echo "   ✅ AnchorStateRegistry found: $ANCHOR_STATE_REGISTRY"
            
            # Update .env.proposer with the correct address
            if grep -q "^ANCHOR_STATE_REGISTRY=" "$PROPOSER_ENV" 2>/dev/null; then
                sed -i "s|^ANCHOR_STATE_REGISTRY=.*|ANCHOR_STATE_REGISTRY=${ANCHOR_STATE_REGISTRY}|" "$PROPOSER_ENV"
            else
                echo "ANCHOR_STATE_REGISTRY=${ANCHOR_STATE_REGISTRY}" >> "$PROPOSER_ENV"
            fi
            echo "   ✅ Updated ANCHOR_STATE_REGISTRY in .env.proposer"
        else
            echo "❌ Error: OPTIMISM_PORTAL_PROXY_ADDRESS not set, cannot find AnchorStateRegistry"
            return 1
        fi
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
        \
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
    
    # Export for parent script
    export GAME_IMPLEMENTATION=$NEW_GAME_ADDRESS
}
