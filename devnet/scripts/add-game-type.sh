#!/bin/bash

set -e

# Source environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$(dirname "$SCRIPT_DIR")/.env"
source "$ENV_FILE"

# Validate OWNER_TYPE configuration
if [ "$OWNER_TYPE" != "transactor" ] && [ "$OWNER_TYPE" != "safe" ]; then
    echo "❌ Error: Invalid OWNER_TYPE '$OWNER_TYPE'. Must be 'transactor' or 'safe'"
    exit 1
fi

echo "=== Using OWNER_TYPE: $OWNER_TYPE ==="

# Function to set respected game type
set_respected_game_type() {
    local GAME_TYPE=${1:-0}  # Default to game type 0

    echo "=== Setting Respected Game Type to $GAME_TYPE ==="

    # Get contract addresses
    echo " 📋 Gathering contract addresses..."
    DISPUTE_GAME_FACTORY_ADDR=$(cast call --rpc-url $L1_RPC_URL $SYSTEM_CONFIG_PROXY_ADDRESS 'disputeGameFactory()(address)')
    OPTIMISM_PORTAL_ADDR=$(cast call --rpc-url $L1_RPC_URL $SYSTEM_CONFIG_PROXY_ADDRESS 'optimismPortal()(address)')
    ANCHOR_STATE_REGISTRY_ADDR=$(cast call --rpc-url $L1_RPC_URL $OPTIMISM_PORTAL_ADDR 'anchorStateRegistry()(address)')
    GAME_ADDR=$(cast call --rpc-url $L1_RPC_URL $DISPUTE_GAME_FACTORY_ADDR 'gameImpls(uint32)(address)' $GAME_TYPE)

    echo "Contract addresses:"
    echo "  Dispute Game Factory: $DISPUTE_GAME_FACTORY_ADDR"
    echo "  Optimism Portal: $OPTIMISM_PORTAL_ADDR"
    echo "  Anchor State Registry: $ANCHOR_STATE_REGISTRY_ADDR"
    echo "  Game Implementation ($GAME_TYPE): $GAME_ADDR"
    echo ""

    # Execute transaction and capture output
    echo "Setting respected game type to $GAME_TYPE..."
    # Use --legacy to force Type 0 transactions, avoiding EIP-1559 gas estimation issues on local testnet
    TX_OUTPUT=$(cast send \
        --json \
        --legacy \
        --rpc-url $L1_RPC_URL \
        --private-key $DEPLOYER_PRIVATE_KEY \
        --from $(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY) \
        $ANCHOR_STATE_REGISTRY_ADDR \
        'setRespectedGameType(uint32)' \
        $GAME_TYPE)

    # Extract transaction hash and status
    TX_HASH=$(echo "$TX_OUTPUT" | jq -r '.transactionHash // empty')
    TX_STATUS=$(echo "$TX_OUTPUT" | jq -r '.status // empty')

    echo "Transaction sent, TX_HASH: $TX_HASH"

    # Check if transaction was successful
    if [ "$TX_STATUS" = "0x1" ] || [ "$TX_STATUS" = "1" ]; then
        echo " ✅ setRespectedGameType completed successfully"
    else
        echo " ❌ Transaction failed with status: $TX_STATUS"
        echo "Full output: $TX_OUTPUT"
        exit 1
    fi
}

# Function to add game type via Safe
add_game_type_via_safe() {
    # Check parameter count
    if [ $# -ne 5 ]; then
        echo "Error: add_game_type_via_safe requires exactly 5 parameters"
        echo "Usage: add_game_type_via_safe <GAME_TYPE> <IS_PERMISSIONED> <CLOCK_EXTENSION> <MAX_CLOCK_DURATION> <ABSOLUTE_PRESTATE>"
        echo "Example: add_game_type_via_safe 2 true 600 1800 0x..."
        return 1
    fi

    local GAME_TYPE=$1
    local IS_PERMISSIONED=$2
    local CLOCK_EXTENSION_VAL=$3
    local MAX_CLOCK_DURATION_VAL=$4
    local ABSOLUTE_PRESTATE_VAL=$5

    echo "=== Adding Game Type $GAME_TYPE via Safe ==="
    echo "  Game Type: $GAME_TYPE"
    echo "  Is Permissioned: $IS_PERMISSIONED"
    echo "  Clock Extension: $CLOCK_EXTENSION_VAL"
    echo "  Max Clock Duration: $MAX_CLOCK_DURATION_VAL"
    echo ""

    # Get dispute game factory address
    DISPUTE_GAME_FACTORY=$(cast call --rpc-url $L1_RPC_URL $SYSTEM_CONFIG_PROXY_ADDRESS 'disputeGameFactory()(address)')

    echo "Debug Info:"
    echo "  State JSON: $STATE_JSON_PATH"
    echo "  Dispute Game Factory: $DISPUTE_GAME_FACTORY"
    echo "  System Config: $SYSTEM_CONFIG_PROXY_ADDRESS"
    echo "  Proxy Admin: $PROXY_ADMIN"
    echo "  OPCM: $OPCM_IMPL_ADDRESS"
    echo "  Safe: $SAFE_ADDRESS"
    echo "  RPC URL: $L1_RPC_URL"
    echo "  Sender: $(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY)"
    echo ""

    # Retrieve existing permissioned game implementation for parameters
    echo "Retrieving permissioned game parameters..."
    PERMISSIONED_GAME=$(cast call --rpc-url $L1_RPC_URL $DISPUTE_GAME_FACTORY 'gameImpls(uint32)(address)' 1)
    echo "Permissioned Game Implementation: $PERMISSIONED_GAME"

    if [ "$PERMISSIONED_GAME" == "0x0000000000000000000000000000000000000000" ]; then
        echo "Error: No permissioned game found. Cannot retrieve parameters."
        exit 1
    fi

    # Retrieve parameters from existing permissioned game
    ABSOLUTE_PRESTATE="$ABSOLUTE_PRESTATE_VAL"
    MAX_GAME_DEPTH=$(cast call --rpc-url $L1_RPC_URL $PERMISSIONED_GAME 'maxGameDepth()')
    SPLIT_DEPTH=$(cast call --rpc-url $L1_RPC_URL $PERMISSIONED_GAME 'splitDepth()')
    VM=$(cast call --rpc-url $L1_RPC_URL $PERMISSIONED_GAME 'vm()(address)')

    echo "Retrieved parameters:"
    echo "  Absolute Prestate: $ABSOLUTE_PRESTATE"
    echo "  Max Game Depth: $MAX_GAME_DEPTH"
    echo "  Split Depth: $SPLIT_DEPTH"
    echo "  Clock Extension: $CLOCK_EXTENSION_VAL"
    echo "  Max Clock Duration: $MAX_CLOCK_DURATION_VAL"
    echo "  VM: $VM"
    echo ""

    # Set constants
    INITIAL_BOND='80000000000000000'  # 0.08 ETH in wei
    SALT_MIXER='123'  # Unique salt for game type

    echo "Creating addGameType calldata..."

    # Build game type parameters array (simplified)
    GAME_PARAMS="[(\"$SALT_MIXER\",$SYSTEM_CONFIG_PROXY_ADDRESS,$PROXY_ADMIN,0x0000000000000000000000000000000000000000,$GAME_TYPE,$ABSOLUTE_PRESTATE,$MAX_GAME_DEPTH,$SPLIT_DEPTH,$CLOCK_EXTENSION_VAL,$MAX_CLOCK_DURATION_VAL,$INITIAL_BOND,$VM,$IS_PERMISSIONED)]"

    echo "Parameters prepared for addGameType"

    # Execute the transaction through Safe
    echo "Executing transaction via Safe..."
    echo "Target: $SAFE_ADDRESS"
    echo "From: $(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY)"

    # Simplified DELEGATECALL - build calldata first, then call
    ADDGAMETYPE_CALLDATA=$(cast calldata 'addGameType((string,address,address,address,uint32,bytes32,uint256,uint256,uint64,uint64,uint256,address,bool)[])' "$GAME_PARAMS")


    # Execute transaction via Safe's execTransaction with proper signature
    echo "Executing transaction via Safe with signature..."
    DEPLOYER_ADDRESS=$(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY)

    # Use the calldata we built earlier
    echo "Using calldata: $ADDGAMETYPE_CALLDATA"

    # Get Safe nonce
    SAFE_NONCE=$(cast call --rpc-url $L1_RPC_URL $SAFE_ADDRESS 'nonce()(uint256)')
    echo "Safe nonce: $SAFE_NONCE"

    # Build signature exactly like DeployOwnership.s.sol _callViaSafe method
    # abi.encodePacked(uint256(uint160(msg.sender)), bytes32(0), uint8(1))
    echo "Building signature like DeployOwnership.s.sol _callViaSafe..."

    # Convert deployer address to uint256(uint160(address)) format
    # This is equivalent to: uint256(uint160(msg.sender))
    DEPLOYER_ADDRESS_NO_PREFIX=${DEPLOYER_ADDRESS#0x}
    ADDRESS_LENGTH=${#DEPLOYER_ADDRESS_NO_PREFIX}
    ZEROS_NEEDED=$((64 - ADDRESS_LENGTH))
    ZEROS=$(printf "%0${ZEROS_NEEDED}d" 0)
    DEPLOYER_ADDRESS_PADDED="${ZEROS}${DEPLOYER_ADDRESS_NO_PREFIX}"

    # Build signature: uint256(uint160(msg.sender)) + bytes32(0) + uint8(1)
    # This is exactly what abi.encodePacked(uint256(uint160(msg.sender)), bytes32(0), uint8(1)) produces
    PACKED_SIGNATURE="0x${DEPLOYER_ADDRESS_PADDED}000000000000000000000000000000000000000000000000000000000000000001"

    echo "Deployer address: $DEPLOYER_ADDRESS"
    echo "Signature (abi.encodePacked format): $PACKED_SIGNATURE"
    echo "Signature length: $((${#PACKED_SIGNATURE} - 2)) hex chars = $(((${#PACKED_SIGNATURE} - 2) / 2)) bytes"

    # Execute transaction via Safe's execTransaction
    echo "Executing execTransaction on Safe..."
    TX_OUTPUT=$(cast send \
        --json \
        --legacy \
        --rpc-url $L1_RPC_URL \
        --private-key $DEPLOYER_PRIVATE_KEY \
        --from $DEPLOYER_ADDRESS \
        $SAFE_ADDRESS \
        'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)' \
        $OPCM_IMPL_ADDRESS \
        0 \
        $ADDGAMETYPE_CALLDATA \
        1 \
        0 \
        0 \
        0 \
        0x0000000000000000000000000000000000000000 \
        0x0000000000000000000000000000000000000000 \
        $PACKED_SIGNATURE)

    # Extract transaction hash and status
    TX_HASH=$(echo "$TX_OUTPUT" | jq -r '.transactionHash // empty')
    TX_STATUS=$(echo "$TX_OUTPUT" | jq -r '.status // empty')

    echo ""
    echo "Transaction sent, TX_HASH: $TX_HASH"

    # Check if transaction was successful
    if [ "$TX_STATUS" = "0x1" ] || [ "$TX_STATUS" = "1" ]; then
        echo " ✅ Transaction successful!"
    else
        echo " ❌ Transaction failed with status: $TX_STATUS"
        echo "Full output: $TX_OUTPUT"
        exit 1
    fi
    echo ""

    # Verify the new game type was added
    echo "Verifying new game type was added..."
    NEW_GAME_IMPL=$(cast call --rpc-url $L1_RPC_URL $DISPUTE_GAME_FACTORY 'gameImpls(uint32)(address)' $GAME_TYPE)

    if [ "$NEW_GAME_IMPL" != "0x0000000000000000000000000000000000000000" ] && [ "$NEW_GAME_IMPL" != "$PERMISSIONED_GAME" ]; then
        echo " ✅ Success! New game type $GAME_TYPE added."
        echo "Game Type $GAME_TYPE Implementation: $NEW_GAME_IMPL"
    else
        echo " ❌ Warning: Could not verify game type was added. Check transaction status."
    fi

    echo " ✅ AddGameType operations completed successfully"

    # Set the newly added game type as respected
    echo ""
    set_respected_game_type "$GAME_TYPE"
}

# Function to add game type via Transactor
add_game_type_via_transactor() {
    # Check parameter count
    if [ $# -ne 5 ]; then
        echo "Error: add_game_type_via_transactor requires exactly 5 parameters"
        echo "Usage: add_game_type_via_transactor <GAME_TYPE> <IS_PERMISSIONED> <CLOCK_EXTENSION> <MAX_CLOCK_DURATION> <ABSOLUTE_PRESTATE>"
        echo "Example: add_game_type_via_transactor 2 true 600 1800 0x..."
        return 1
    fi

    local GAME_TYPE=$1
    local IS_PERMISSIONED=$2
    local CLOCK_EXTENSION_VAL=$3
    local MAX_CLOCK_DURATION_VAL=$4
    local ABSOLUTE_PRESTATE_VAL=$5

    echo "=== Adding Game Type $GAME_TYPE via Transactor ==="
    echo "  Game Type: $GAME_TYPE"
    echo "  Is Permissioned: $IS_PERMISSIONED"
    echo "  Clock Extension: $CLOCK_EXTENSION_VAL"
    echo "  Max Clock Duration: $MAX_CLOCK_DURATION_VAL"
    echo ""

    # Get dispute game factory address
    DISPUTE_GAME_FACTORY=$(cast call --rpc-url $L1_RPC_URL $SYSTEM_CONFIG_PROXY_ADDRESS 'disputeGameFactory()(address)')

    echo "Debug Info:"
    echo "  Dispute Game Factory: $DISPUTE_GAME_FACTORY"
    echo "  System Config: $SYSTEM_CONFIG_PROXY_ADDRESS"
    echo "  Proxy Admin: $PROXY_ADMIN"
    echo "  OPCM: $OPCM_IMPL_ADDRESS"
    echo "  Transactor: $TRANSACTOR"
    echo "  RPC URL: $L1_RPC_URL"
    echo "  Sender: $(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY)"
    echo ""

    # Retrieve existing permissioned game implementation for parameters
    echo "Retrieving permissioned game parameters..."
    PERMISSIONED_GAME=$(cast call --rpc-url $L1_RPC_URL $DISPUTE_GAME_FACTORY 'gameImpls(uint32)(address)' 1)
    echo "Permissioned Game Implementation: $PERMISSIONED_GAME"

    if [ "$PERMISSIONED_GAME" == "0x0000000000000000000000000000000000000000" ]; then
        echo "Error: No permissioned game found. Cannot retrieve parameters."
        exit 1
    fi

    # Retrieve parameters from existing permissioned game
    ABSOLUTE_PRESTATE="$ABSOLUTE_PRESTATE_VAL"
    MAX_GAME_DEPTH=$(cast call --rpc-url $L1_RPC_URL $PERMISSIONED_GAME 'maxGameDepth()')
    SPLIT_DEPTH=$(cast call --rpc-url $L1_RPC_URL $PERMISSIONED_GAME 'splitDepth()')
    VM=$(cast call --rpc-url $L1_RPC_URL $PERMISSIONED_GAME 'vm()(address)')

    echo "Retrieved parameters:"
    echo "  Absolute Prestate: $ABSOLUTE_PRESTATE"
    echo "  Max Game Depth: $MAX_GAME_DEPTH"
    echo "  Split Depth: $SPLIT_DEPTH"
    echo "  Clock Extension: $CLOCK_EXTENSION_VAL"
    echo "  Max Clock Duration: $MAX_CLOCK_DURATION_VAL"
    echo "  VM: $VM"
    echo ""

    # Set constants
    INITIAL_BOND='80000000000000000'  # 0.08 ETH in wei
    SALT_MIXER='123'  # Unique salt for game type

    echo "Creating addGameType calldata..."

    # Build game type parameters array
    GAME_PARAMS="[(\"$SALT_MIXER\",$SYSTEM_CONFIG_PROXY_ADDRESS,$PROXY_ADMIN,0x0000000000000000000000000000000000000000,$GAME_TYPE,$ABSOLUTE_PRESTATE,$MAX_GAME_DEPTH,$SPLIT_DEPTH,$CLOCK_EXTENSION_VAL,$MAX_CLOCK_DURATION_VAL,$INITIAL_BOND,$VM,$IS_PERMISSIONED)]"

    echo "Parameters prepared for addGameType"

    # Build calldata for addGameType
    ADDGAMETYPE_CALLDATA=$(cast calldata 'addGameType((string,address,address,address,uint32,bytes32,uint256,uint256,uint64,uint64,uint256,address,bool)[])' "$GAME_PARAMS")

    echo "Executing DELEGATECALL via Transactor..."
    echo "TRANSACTOR address: $TRANSACTOR"
    echo "TRANSACTOR address length: ${#TRANSACTOR}"

    # Execute through Transactor's DELEGATECALL method
    TX_OUTPUT=$(cast send \
        --json \
        --legacy \
        --rpc-url $L1_RPC_URL \
        --private-key $DEPLOYER_PRIVATE_KEY \
        --from $(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY) \
        $TRANSACTOR \
        'DELEGATECALL(address,bytes)' \
        $OPCM_IMPL_ADDRESS \
        $ADDGAMETYPE_CALLDATA)

    # Extract transaction hash and status
    TX_HASH=$(echo "$TX_OUTPUT" | jq -r '.transactionHash // empty')
    TX_STATUS=$(echo "$TX_OUTPUT" | jq -r '.status // empty')

    echo ""
    echo "Transaction sent, TX_HASH: $TX_HASH"

    # Check if transaction was successful
    if [ "$TX_STATUS" = "0x1" ] || [ "$TX_STATUS" = "1" ]; then
        echo " ✅ Transaction successful!"
    else
        echo " ❌ Transaction failed with status: $TX_STATUS"
        echo "Full output: $TX_OUTPUT"
        exit 1
    fi
    echo ""

    # Verify the new game type was added
    echo "Verifying new game type was added..."
    NEW_GAME_IMPL=$(cast call --rpc-url $L1_RPC_URL $DISPUTE_GAME_FACTORY 'gameImpls(uint32)(address)' $GAME_TYPE)

    if [ "$NEW_GAME_IMPL" != "0x0000000000000000000000000000000000000000" ] && [ "$NEW_GAME_IMPL" != "$PERMISSIONED_GAME" ]; then
        echo " ✅ Success! New game type $GAME_TYPE added."
        echo "Game Type $GAME_TYPE Implementation: $NEW_GAME_IMPL"
    else
        echo " ❌ Warning: Could not verify game type was added. Check transaction status."
    fi

    echo " ✅ AddGameType operations completed successfully"

    # Set the newly added game type as respected
    echo ""
    set_respected_game_type "$GAME_TYPE"
}

# Main execution
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    # Script is being executed directly - choose function based on OWNER_TYPE
    if [ "$OWNER_TYPE" = "safe" ]; then
        add_game_type_via_safe "$@"
    elif [ "$OWNER_TYPE" = "transactor" ]; then
        add_game_type_via_transactor "$@"
    else
        echo "Error: Invalid OWNER_TYPE '$OWNER_TYPE'"
        exit 1
    fi
fi
