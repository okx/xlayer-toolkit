#!/usr/bin/env bash
# resolve-tee-game.sh — Resolve TEE dispute games
#
# Usage:
#   bash scripts/resolve-tee-game.sh <game_index>

set -euo pipefail

# ════════════════════════════════════════════════════════════════
# Configuration
# ════════════════════════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVNET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

[ -f "$DEVNET_DIR/.env" ] && source "$DEVNET_DIR/.env"

FACTORY_ADDRESS=${DISPUTE_GAME_FACTORY_ADDRESS:-""}
L1_RPC=${L1_RPC_URL:-"http://localhost:8545"}
CHALLENGER_KEY=${OP_CHALLENGER_PRIVATE_KEY:-""}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ════════════════════════════════════════════════════════════════
# Usage
# ════════════════════════════════════════════════════════════════
usage() {
    echo "Usage:"
    echo "  $0 <game_index>"
    echo ""
    echo "  Wait for gameOver, resolve the game, and claim credit if challenger wins."
    exit 1
}

# ════════════════════════════════════════════════════════════════
# Requirement Checking
# ════════════════════════════════════════════════════════════════
check_requirements() {
    if ! command -v cast &>/dev/null; then
        echo -e "${RED}Error: 'cast' not found. Install Foundry: https://getfoundry.sh${NC}"
        exit 1
    fi

    if [[ -z "$FACTORY_ADDRESS" ]]; then
        echo -e "${RED}Error: DISPUTE_GAME_FACTORY_ADDRESS not set in .env${NC}"
        exit 1
    fi

    if [[ -z "$CHALLENGER_KEY" ]]; then
        echo -e "${RED}Error: OP_CHALLENGER_PRIVATE_KEY not set in .env${NC}"
        exit 1
    fi
}

# ════════════════════════════════════════════════════════════════
# Helpers
# ════════════════════════════════════════════════════════════════
game_status_name() {
    case "$1" in
        0) echo "IN_PROGRESS" ;;
        1) echo "CHALLENGER_WINS" ;;
        2) echo "DEFENDER_WINS" ;;
        *) echo "Unknown($1)" ;;
    esac
}

# ════════════════════════════════════════════════════════════════
# Resolve a single game
# ════════════════════════════════════════════════════════════════
resolve_game() {
    local GAME_ADDR="$1"
    local GAME_INDEX="$2"

    echo -e "${CYAN}Waiting for game #$GAME_INDEX to be over...${NC}"
    while true; do
        GAME_OVER=$(cast call "$GAME_ADDR" "gameOver()(bool)" --rpc-url "$L1_RPC" 2>/dev/null)
        if [[ "$GAME_OVER" == "true" ]]; then
            echo -e "  ${GREEN}✅ Game is over${NC}"
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""

    echo -e "${CYAN}Resolving game #$GAME_INDEX...${NC}"
    TX=$(cast send --private-key "$CHALLENGER_KEY" \
        --rpc-url "$L1_RPC" \
        --json \
        "$GAME_ADDR" "resolve()" 2>&1) || true

    TX_HASH=$(echo "$TX" | jq -r '.transactionHash // empty' 2>/dev/null)
    TX_STATUS=$(echo "$TX" | jq -r '.status // empty' 2>/dev/null)

    if [[ "$TX_STATUS" == "0x1" ]]; then
        echo -e "  ${GREEN}✅ Resolved! TX: $TX_HASH${NC}"
    else
        echo -e "  ${RED}❌ Resolve failed! TX: ${TX_HASH:-N/A}${NC}"
        return 1
    fi

    # Show result
    GAME_STATUS=$(cast call "$GAME_ADDR" "status()(uint8)" --rpc-url "$L1_RPC")
    echo -e "  ${BOLD}Result:${NC} $(game_status_name "$GAME_STATUS")"

    # Claim credit if challenger wins
    if [[ "$GAME_STATUS" == "1" ]]; then
        echo -e "  ${CYAN}Challenger wins! Claiming credit...${NC}"
        FINALITY_DELAY=${DISPUTE_GAME_FINALITY_DELAY_SECONDS:-0}
        if [[ "$FINALITY_DELAY" -gt 0 ]]; then
            echo "  Waiting ${FINALITY_DELAY}s for finality delay..."
            sleep "$FINALITY_DELAY"
            sleep 1
        fi

        TX=$(cast send --private-key "$CHALLENGER_KEY" \
            --rpc-url "$L1_RPC" \
            --json \
            "$GAME_ADDR" "claimCredit(address)" "$CHALLENGER_ADDR" 2>&1) || true

        TX_HASH=$(echo "$TX" | jq -r '.transactionHash // empty' 2>/dev/null)
        TX_STATUS=$(echo "$TX" | jq -r '.status // empty' 2>/dev/null)

        if [[ "$TX_STATUS" == "0x1" ]]; then
            echo -e "  ${GREEN}✅ Credit claimed! TX: $TX_HASH${NC}"
        else
            echo -e "  ${YELLOW}⚠️  claimCredit failed (may need to wait longer)${NC}"
        fi
    fi
}

# ════════════════════════════════════════════════════════════════
# Main
# ════════════════════════════════════════════════════════════════
check_requirements

if [[ $# -lt 1 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    usage
fi

GAME_INDEX="$1"

if ! [[ "$GAME_INDEX" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: game_index must be a non-negative integer${NC}"
    exit 1
fi

CHALLENGER_ADDR=$(cast wallet address "$CHALLENGER_KEY")

echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}${BOLD}  TEE Dispute Game Resolver${NC}"
echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

TOTAL=$(cast call "$FACTORY_ADDRESS" "gameCount()(uint256)" --rpc-url "$L1_RPC")
if [[ "$GAME_INDEX" -ge "$TOTAL" ]]; then
    echo -e "${RED}Error: game index $GAME_INDEX out of range (total: $TOTAL)${NC}"
    exit 1
fi

INFO=$(cast call "$FACTORY_ADDRESS" "gameAtIndex(uint256)(uint32,uint64,address)" "$GAME_INDEX" --rpc-url "$L1_RPC")
GAME_TYPE=$(echo "$INFO" | awk 'NR==1')
GAME_ADDR=$(echo "$INFO" | awk 'NR==3')

echo -e "  ${BOLD}Game Index:${NC}    $GAME_INDEX"
echo -e "  ${BOLD}Game Type:${NC}     $GAME_TYPE"
echo -e "  ${BOLD}Game Address:${NC}  $GAME_ADDR"
echo -e "  ${BOLD}Challenger:${NC}    $CHALLENGER_ADDR"
echo ""

resolve_game "$GAME_ADDR" "$GAME_INDEX"

echo ""
echo -e "${GREEN}${BOLD}Done.${NC}"
