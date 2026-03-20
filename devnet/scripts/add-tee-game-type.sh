#!/bin/bash
# add-tee-game-type.sh — Register TeeDisputeGame on an existing devnet
#
# Usage:
#   ./scripts/add-tee-game-type.sh [--mock-verifier] [/path/to/tee-contracts]
#
# Flags:
#   --mock-verifier   Deploy MockTeeProofVerifier instead of TeeProofVerifier.
#                     Use when you want a fully mock verifier (no ECDSA signing needed).
#
# If no path is given, defaults to <devnet-dir>/tee-contracts.
# You can also set TEE_CONTRACTS_DIR explicitly:
#   TEE_CONTRACTS_DIR=/path/to/tee-contracts ./scripts/add-tee-game-type.sh

set -e

# ── Parse flags ───────────────────────────────────────────────────────────────
USE_MOCK_VERIFIER=false
POSITIONAL_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --mock-verifier) USE_MOCK_VERIFIER=true ;;
        *) POSITIONAL_ARGS+=("$arg") ;;
    esac
done

# Source environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVNET_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$DEVNET_DIR/.env"
source "$ENV_FILE"

# Resolve tee-contracts directory: positional arg > TEE_CONTRACTS_DIR env > default
if [ "${#POSITIONAL_ARGS[@]}" -gt 0 ]; then
    TEE_CONTRACTS_DIR="${POSITIONAL_ARGS[0]}"
elif [ -z "$TEE_CONTRACTS_DIR" ]; then
    TEE_CONTRACTS_DIR="$DEVNET_DIR/tee-contracts"
fi

if [ ! -f "$TEE_CONTRACTS_DIR/foundry.toml" ]; then
    echo "❌  Cannot find tee-contracts at: $TEE_CONTRACTS_DIR"
    echo "    Pass the directory as the first argument or set TEE_CONTRACTS_DIR."
    exit 1
fi

echo "=== Using tee-contracts: $TEE_CONTRACTS_DIR ==="

# TeeDisputeGame game type (must match TEE_DISPUTE_GAME_TYPE in AccessManager.sol)
TEE_GAME_TYPE=1960

# Validate OWNER_TYPE configuration
if [ "$OWNER_TYPE" != "transactor" ] && [ "$OWNER_TYPE" != "safe" ]; then
    echo "❌ Error: Invalid OWNER_TYPE '$OWNER_TYPE'. Must be 'transactor' or 'safe'"
    exit 1
fi

echo "=== Using OWNER_TYPE: $OWNER_TYPE ==="

# Resolve on-chain addresses
echo "=== Resolving on-chain addresses ==="
DISPUTE_GAME_FACTORY_ADDR=$(cast call --rpc-url $L1_RPC_URL $SYSTEM_CONFIG_PROXY_ADDRESS 'disputeGameFactory()(address)')
OPTIMISM_PORTAL_ADDR=$(cast call --rpc-url $L1_RPC_URL $SYSTEM_CONFIG_PROXY_ADDRESS 'optimismPortal()(address)')
ANCHOR_STATE_REGISTRY_ADDR=$(cast call --rpc-url $L1_RPC_URL $OPTIMISM_PORTAL_ADDR 'anchorStateRegistry()(address)')

echo "  Existing DGF:            $DISPUTE_GAME_FACTORY_ADDR"
echo "  OptimismPortal:          $OPTIMISM_PORTAL_ADDR"
echo "  Existing ASR:            $ANCHOR_STATE_REGISTRY_ADDR"
echo ""

# Export env vars consumed by DevnetAddTeeGame.s.sol
export PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY"
export EXISTING_DGF="$DISPUTE_GAME_FACTORY_ADDR"
export EXISTING_ASR="$ANCHOR_STATE_REGISTRY_ADDR"
export SYSTEM_CONFIG_ADDRESS="$SYSTEM_CONFIG_PROXY_ADDRESS"
export DISPUTE_GAME_FINALITY_DELAY_SECONDS="${DISPUTE_GAME_FINALITY_DELAY_SECONDS:-5}"

# TEE game timing — reuse devnet values for fast iteration
export MAX_CHALLENGE_DURATION="${MAX_CLOCK_DURATION:-20}"
export MAX_PROVE_DURATION="${MAX_CLOCK_DURATION:-20}"

# Bond defaults (0.01 ETH) and access-manager fallback timeout (1 hour)
export CHALLENGER_BOND="${CHALLENGER_BOND:-10000000000000000}"
export FALLBACK_TIMEOUT="${FALLBACK_TIMEOUT:-3600}"
export INIT_BOND="${INIT_BOND:-10000000000000000}"

if [ -n "$PROPOSER_ADDRESS" ]; then
    export PROPOSER_ADDRESS
else
    unset PROPOSER_ADDRESS
fi

export USE_MOCK_VERIFIER
echo "=== Verifier mode: $([ "$USE_MOCK_VERIFIER" = "true" ] && echo "MockTeeProofVerifier (mock)" || echo "TeeProofVerifier + MockRiscZeroVerifier") ==="

# ── Function: deploy TEE contracts via forge script ───────────────────────────
deploy_tee_contracts() {
    echo "=== Deploying TEE contracts via forge script ==="

    FORGE_LOG=$(mktemp)
    # Ensure temp file is cleaned up on any exit (including set -e failures)
    trap 'rm -f "${FORGE_LOG:-}"' RETURN

    # Auto-detect scripts subdirectory: new-style repos use "scripts/", old-style use "script/"
    if [ -f "$TEE_CONTRACTS_DIR/scripts/DevnetAddTeeGame.s.sol" ]; then
        FORGE_SCRIPT_SUBDIR="scripts"
    else
        FORGE_SCRIPT_SUBDIR="script"
    fi

    # pushd/popd avoids persistent cwd change (plain `cd` inside a non-subshell
    # function would affect the rest of the script)
    pushd "$TEE_CONTRACTS_DIR" > /dev/null
    forge script "${FORGE_SCRIPT_SUBDIR}/DevnetAddTeeGame.s.sol:DevnetAddTeeGame" \
        --rpc-url "$L1_RPC_URL" \
        --broadcast \
        --legacy \
        -vv 2>&1 | tee "$FORGE_LOG"
    popd > /dev/null

    if ! grep -q "ONCHAIN EXECUTION COMPLETE" "$FORGE_LOG"; then
        echo ""
        echo "❌ Deployment failed — check output above."
        exit 1
    fi

    # Extract deployed addresses from forge log (grep for console2.log lines)
    _addr() { grep "$1" "$FORGE_LOG" | grep -oE '0x[0-9a-fA-F]{40}' | head -1; }

    TEE_GAME_IMPL=$(_addr "TeeDisputeGame impl")
    NEW_ASR_ADDR=$(_addr "New AnchorStateRegistry")

    echo ""
    echo "  TeeDisputeGame impl:     $TEE_GAME_IMPL"
    echo "  New AnchorStateRegistry: $NEW_ASR_ADDR"
    echo ""

    if [ -z "$TEE_GAME_IMPL" ]; then
        echo "❌ Failed to extract TeeDisputeGame impl address from forge log."
        exit 1
    fi
    if [ -z "$NEW_ASR_ADDR" ]; then
        echo "❌ Failed to extract New AnchorStateRegistry address from forge log."
        exit 1
    fi
}

# ── Function: setRespectedGameType on new ASR ─────────────────────────────────
set_respected_game_type() {
    echo "=== Setting Respected Game Type to $TEE_GAME_TYPE on new ASR ==="
    echo "  New ASR: $NEW_ASR_ADDR"
    echo ""

    # The deployer IS the guardian on devnet (SystemConfig.guardian() == deployer)
    TX_OUTPUT=$(cast send \
        --json \
        --legacy \
        --rpc-url $L1_RPC_URL \
        --private-key $DEPLOYER_PRIVATE_KEY \
        --from $(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY) \
        $NEW_ASR_ADDR \
        'setRespectedGameType(uint32)' \
        $TEE_GAME_TYPE)

    TX_HASH=$(echo "$TX_OUTPUT" | jq -r '.transactionHash // empty')
    TX_STATUS=$(echo "$TX_OUTPUT" | jq -r '.status // empty')
    echo "Transaction sent, TX_HASH: $TX_HASH"

    if [ "$TX_STATUS" = "0x1" ] || [ "$TX_STATUS" = "1" ]; then
        echo " ✅ setRespectedGameType($TEE_GAME_TYPE) completed successfully"
    else
        echo " ❌ Transaction failed with status: $TX_STATUS"
        echo "Full output: $TX_OUTPUT"
        exit 1
    fi
    echo ""
}

# ── Function: register TEE game type via Transactor ───────────────────────────
add_tee_game_type_via_transactor() {
    echo "=== Registering TeeDisputeGame (type $TEE_GAME_TYPE) via Transactor ==="
    echo "  Transactor:              $TRANSACTOR"
    echo "  Existing DGF:            $DISPUTE_GAME_FACTORY_ADDR"
    echo "  TeeDisputeGame impl:     $TEE_GAME_IMPL"
    echo "  Sender:                  $(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY)"
    echo ""

    # Build calldata for setImplementation(uint32,address)
    SET_IMPL_CALLDATA=$(cast calldata 'setImplementation(uint32,address)' $TEE_GAME_TYPE $TEE_GAME_IMPL)
    echo "setImplementation calldata: $SET_IMPL_CALLDATA"

    echo "Executing CALL via Transactor (setImplementation)..."
    TX_OUTPUT=$(cast send \
        --json \
        --legacy \
        --rpc-url $L1_RPC_URL \
        --private-key $DEPLOYER_PRIVATE_KEY \
        --from $(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY) \
        $TRANSACTOR \
        'CALL(address,bytes,uint256)' \
        $DISPUTE_GAME_FACTORY_ADDR \
        $SET_IMPL_CALLDATA \
        0)

    TX_HASH=$(echo "$TX_OUTPUT" | jq -r '.transactionHash // empty')
    TX_STATUS=$(echo "$TX_OUTPUT" | jq -r '.status // empty')
    echo ""
    echo "Transaction sent, TX_HASH: $TX_HASH"

    if [ "$TX_STATUS" = "0x1" ] || [ "$TX_STATUS" = "1" ]; then
        echo " ✅ setImplementation successful!"
    else
        echo " ❌ Transaction failed with status: $TX_STATUS"
        echo "Full output: $TX_OUTPUT"
        exit 1
    fi
    echo ""

    # Build calldata for setInitBond(uint32,uint256)
    SET_BOND_CALLDATA=$(cast calldata 'setInitBond(uint32,uint256)' $TEE_GAME_TYPE $INIT_BOND)
    echo "setInitBond calldata: $SET_BOND_CALLDATA"

    echo "Executing CALL via Transactor (setInitBond)..."
    TX_OUTPUT=$(cast send \
        --json \
        --legacy \
        --rpc-url $L1_RPC_URL \
        --private-key $DEPLOYER_PRIVATE_KEY \
        --from $(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY) \
        $TRANSACTOR \
        'CALL(address,bytes,uint256)' \
        $DISPUTE_GAME_FACTORY_ADDR \
        $SET_BOND_CALLDATA \
        0)

    TX_HASH=$(echo "$TX_OUTPUT" | jq -r '.transactionHash // empty')
    TX_STATUS=$(echo "$TX_OUTPUT" | jq -r '.status // empty')
    echo ""
    echo "Transaction sent, TX_HASH: $TX_HASH"

    if [ "$TX_STATUS" = "0x1" ] || [ "$TX_STATUS" = "1" ]; then
        echo " ✅ setInitBond successful!"
    else
        echo " ❌ Transaction failed with status: $TX_STATUS"
        echo "Full output: $TX_OUTPUT"
        exit 1
    fi
    echo ""
}

# ── Function: register TEE game type via Safe ─────────────────────────────────
add_tee_game_type_via_safe() {
    echo "=== Registering TeeDisputeGame (type $TEE_GAME_TYPE) via Safe ==="
    echo "  Safe:                    $SAFE_ADDRESS"
    echo "  Existing DGF:            $DISPUTE_GAME_FACTORY_ADDR"
    echo "  TeeDisputeGame impl:     $TEE_GAME_IMPL"
    echo "  Sender:                  $(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY)"
    echo ""

    DEPLOYER_ADDRESS=$(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY)

    # Build signature like DeployOwnership.s.sol _callViaSafe method
    DEPLOYER_ADDRESS_NO_PREFIX=${DEPLOYER_ADDRESS#0x}
    ADDRESS_LENGTH=${#DEPLOYER_ADDRESS_NO_PREFIX}
    ZEROS_NEEDED=$((64 - ADDRESS_LENGTH))
    ZEROS=$(printf "%0${ZEROS_NEEDED}d" 0)
    DEPLOYER_ADDRESS_PADDED="${ZEROS}${DEPLOYER_ADDRESS_NO_PREFIX}"

    # Build signature: uint256(uint160(msg.sender)) + bytes32(0) + uint8(1)
    PACKED_SIGNATURE="0x${DEPLOYER_ADDRESS_PADDED}000000000000000000000000000000000000000000000000000000000000000001"

    echo "Deployer address: $DEPLOYER_ADDRESS"
    echo "Signature (abi.encodePacked format): $PACKED_SIGNATURE"
    echo ""

    # setImplementation(uint32,address)
    SET_IMPL_CALLDATA=$(cast calldata 'setImplementation(uint32,address)' $TEE_GAME_TYPE $TEE_GAME_IMPL)
    echo "setImplementation calldata: $SET_IMPL_CALLDATA"

    echo "Executing execTransaction on Safe (setImplementation)..."
    TX_OUTPUT=$(cast send \
        --json \
        --legacy \
        --rpc-url $L1_RPC_URL \
        --private-key $DEPLOYER_PRIVATE_KEY \
        --from $DEPLOYER_ADDRESS \
        $SAFE_ADDRESS \
        'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)' \
        $DISPUTE_GAME_FACTORY_ADDR \
        0 \
        $SET_IMPL_CALLDATA \
        0 \
        0 \
        0 \
        0 \
        0x0000000000000000000000000000000000000000 \
        0x0000000000000000000000000000000000000000 \
        $PACKED_SIGNATURE)

    TX_HASH=$(echo "$TX_OUTPUT" | jq -r '.transactionHash // empty')
    TX_STATUS=$(echo "$TX_OUTPUT" | jq -r '.status // empty')
    echo ""
    echo "Transaction sent, TX_HASH: $TX_HASH"

    if [ "$TX_STATUS" = "0x1" ] || [ "$TX_STATUS" = "1" ]; then
        echo " ✅ setImplementation successful!"
    else
        echo " ❌ Transaction failed with status: $TX_STATUS"
        echo "Full output: $TX_OUTPUT"
        exit 1
    fi
    echo ""

    # setInitBond(uint32,uint256)
    SET_BOND_CALLDATA=$(cast calldata 'setInitBond(uint32,uint256)' $TEE_GAME_TYPE $INIT_BOND)
    echo "setInitBond calldata: $SET_BOND_CALLDATA"

    echo "Executing execTransaction on Safe (setInitBond)..."
    TX_OUTPUT=$(cast send \
        --json \
        --legacy \
        --rpc-url $L1_RPC_URL \
        --private-key $DEPLOYER_PRIVATE_KEY \
        --from $DEPLOYER_ADDRESS \
        $SAFE_ADDRESS \
        'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)' \
        $DISPUTE_GAME_FACTORY_ADDR \
        0 \
        $SET_BOND_CALLDATA \
        0 \
        0 \
        0 \
        0 \
        0x0000000000000000000000000000000000000000 \
        0x0000000000000000000000000000000000000000 \
        $PACKED_SIGNATURE)

    TX_HASH=$(echo "$TX_OUTPUT" | jq -r '.transactionHash // empty')
    TX_STATUS=$(echo "$TX_OUTPUT" | jq -r '.status // empty')
    echo ""
    echo "Transaction sent, TX_HASH: $TX_HASH"

    if [ "$TX_STATUS" = "0x1" ] || [ "$TX_STATUS" = "1" ]; then
        echo " ✅ setInitBond successful!"
    else
        echo " ❌ Transaction failed with status: $TX_STATUS"
        echo "Full output: $TX_OUTPUT"
        exit 1
    fi
    echo ""
}

# ── Main execution ─────────────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    # 1. Deploy contracts via forge script
    deploy_tee_contracts

    # 2. setRespectedGameType(1960) on new ASR (deployer is guardian on devnet)
    set_respected_game_type

    # 3. setImplementation + setInitBond on existing DGF via TRANSACTOR or Safe
    if [ "$OWNER_TYPE" = "transactor" ]; then
        add_tee_game_type_via_transactor
    elif [ "$OWNER_TYPE" = "safe" ]; then
        add_tee_game_type_via_safe
    fi

    # 4. Verify
    echo "=== Verifying TeeDisputeGame type was registered ==="
    REGISTERED_IMPL=$(cast call --rpc-url $L1_RPC_URL $DISPUTE_GAME_FACTORY_ADDR 'gameImpls(uint32)(address)' $TEE_GAME_TYPE)
    REGISTERED_BOND=$(cast call --rpc-url $L1_RPC_URL $DISPUTE_GAME_FACTORY_ADDR 'initBonds(uint32)(uint256)' $TEE_GAME_TYPE | awk '{print $1}')

    if [ "$REGISTERED_IMPL" != "0x0000000000000000000000000000000000000000" ]; then
        echo " ✅ Success! TeeDisputeGame type $TEE_GAME_TYPE registered."
        echo "  Implementation: $REGISTERED_IMPL"
    else
        echo " ❌ Warning: Could not verify game type was registered. Check transaction status."
    fi

    if [ "$REGISTERED_BOND" = "$INIT_BOND" ]; then
        echo " ✅ initBond correctly set to $REGISTERED_BOND wei."
    else
        echo " ❌ Warning: initBond mismatch — expected $INIT_BOND, got $REGISTERED_BOND."
    fi

    echo ""
    echo "========================================"
    echo "  TEE Game Type — Final Summary"
    echo "========================================"
    echo "  Game Type:               $TEE_GAME_TYPE"
    echo "  TeeDisputeGame impl:     $TEE_GAME_IMPL"
    echo "  New AnchorStateRegistry: $NEW_ASR_ADDR"
    echo "  Existing DGF:            $DISPUTE_GAME_FACTORY_ADDR"
    echo "========================================"
    echo ""
    echo "Verify:"
    echo "  cast call $DISPUTE_GAME_FACTORY_ADDR 'gameImpls(uint32)(address)' 1960"
    echo "  cast call $NEW_ASR_ADDR 'respectedGameType()(uint32)'"
    echo " ✅ add-tee-game-type completed successfully."
fi
