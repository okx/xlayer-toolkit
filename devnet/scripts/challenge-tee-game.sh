#!/usr/bin/env bash
# challenge-tee-game.sh — Challenge TEE dispute games
#
# Usage:
#   bash scripts/challenge-tee-game.sh <game_index>              # challenge a single game
#   bash scripts/challenge-tee-game.sh <game_index> --resolve    # challenge + wait + resolve
#   bash scripts/challenge-tee-game.sh --watch [--interval 30]   # watch & challenge all new games

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
TEE_GAME_TYPE=${TEE_GAME_TYPE:-1960}

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
    echo "  $0 <game_index> [--resolve]"
    echo "  $0 --watch [--interval SECONDS] [--resolve]"
    echo ""
    echo "Modes:"
    echo "  <game_index>      Challenge a single game by index"
    echo "  --watch           Periodically scan and challenge all new Unchallenged TEE games"
    echo ""
    echo "Options:"
    echo "  --resolve         After challenging, wait for gameOver and resolve"
    echo "  --interval N      Polling interval in seconds for --watch mode (default: 30)"
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
status_name() {
    case "$1" in
        0) echo "Unchallenged" ;;
        1) echo "Challenged" ;;
        2) echo "UnchallengedAndValidProofProvided" ;;
        3) echo "ChallengedAndValidProofProvided" ;;
        4) echo "Resolved" ;;
        *) echo "Unknown($1)" ;;
    esac
}

game_status_name() {
    case "$1" in
        0) echo "IN_PROGRESS" ;;
        1) echo "CHALLENGER_WINS" ;;
        2) echo "DEFENDER_WINS" ;;
        *) echo "Unknown($1)" ;;
    esac
}

# ════════════════════════════════════════════════════════════════
# Challenge a single game by address
# Returns 0 on success, 1 on skip/failure
# ════════════════════════════════════════════════════════════════
challenge_game() {
    local GAME_ADDR="$1"
    local GAME_INDEX="$2"

    # Check current status
    CLAIM_RAW=$(cast call "$GAME_ADDR" "claimData()(uint32,address,address,bytes32,uint8,uint64)" --rpc-url "$L1_RPC")
    STATUS_RAW=$(echo "$CLAIM_RAW" | awk 'NR==5')

    if [[ "$STATUS_RAW" != "0" ]]; then
        echo -e "  ${YELLOW}Game #$GAME_INDEX ($GAME_ADDR): $(status_name "$STATUS_RAW"), skipping${NC}"
        return 1
    fi

    # Get challenger bond
    BOND_WEI=$(cast call "$GAME_ADDR" "challengerBond()(uint256)" --rpc-url "$L1_RPC" | awk '{print $1}')
    BOND_ETH=$(cast to-unit "$BOND_WEI" ether 2>/dev/null || echo "?")

    echo -e "  ${CYAN}Challenging game #$GAME_INDEX ($GAME_ADDR) — bond: ${BOND_ETH} ETH${NC}"

    TX=$(cast send --private-key "$CHALLENGER_KEY" \
        --value "$BOND_WEI" \
        --rpc-url "$L1_RPC" \
        --json \
        "$GAME_ADDR" "challenge()" 2>&1) || true

    TX_HASH=$(echo "$TX" | jq -r '.transactionHash // empty' 2>/dev/null)
    TX_STATUS=$(echo "$TX" | jq -r '.status // empty' 2>/dev/null)

    if [[ "$TX_STATUS" == "0x1" ]]; then
        echo -e "  ${GREEN}✅ Challenged! TX: $TX_HASH${NC}"
        return 0
    else
        echo -e "  ${RED}❌ Challenge failed! TX: ${TX_HASH:-N/A}${NC}"
        echo "  $TX" | head -5
        return 1
    fi
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
# Watch mode: periodically scan and challenge all new games
# ════════════════════════════════════════════════════════════════
watch_mode() {
    local INTERVAL="$1"
    local DO_RESOLVE="$2"

    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  TEE Dispute Game Auto-Challenger (watch mode)${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Factory:    $FACTORY_ADDRESS"
    echo -e "  Challenger: $CHALLENGER_ADDR"
    echo -e "  Game Type:  $TEE_GAME_TYPE"
    echo -e "  Interval:   ${INTERVAL}s"
    echo -e "  Resolve:    $DO_RESOLVE"
    echo ""

    local LAST_SCANNED=0

    while true; do
        TOTAL=$(cast call "$FACTORY_ADDRESS" "gameCount()(uint256)" --rpc-url "$L1_RPC" 2>/dev/null || echo "0")
        TOTAL=$((TOTAL))

        if [[ "$LAST_SCANNED" -eq 0 ]]; then
            # First run: start from current total to only watch new games
            LAST_SCANNED=$TOTAL
            echo -e "[$(date +'%H:%M:%S')] Starting from game index $TOTAL, waiting for new games..."
        fi

        if [[ "$TOTAL" -gt "$LAST_SCANNED" ]]; then
            echo -e "[$(date +'%H:%M:%S')] ${CYAN}Found $((TOTAL - LAST_SCANNED)) new game(s) (index $LAST_SCANNED..$((TOTAL - 1)))${NC}"

            for (( i=LAST_SCANNED; i<TOTAL; i++ )); do
                # Get game info from factory
                INFO=$(cast call "$FACTORY_ADDRESS" "gameAtIndex(uint256)(uint32,uint64,address)" "$i" --rpc-url "$L1_RPC" 2>/dev/null) || continue
                GAME_TYPE=$(echo "$INFO" | awk 'NR==1')
                GAME_ADDR=$(echo "$INFO" | awk 'NR==3')

                # Only challenge TEE games
                if [[ "$GAME_TYPE" != "$TEE_GAME_TYPE" ]]; then
                    echo -e "  Game #$i: type=$GAME_TYPE, skipping (not TEE)"
                    continue
                fi

                if challenge_game "$GAME_ADDR" "$i"; then
                    if [[ "$DO_RESOLVE" == "true" ]]; then
                        resolve_game "$GAME_ADDR" "$i"
                    fi
                fi
                echo ""
            done

            LAST_SCANNED=$TOTAL
        fi

        sleep "$INTERVAL"
    done
}

# ════════════════════════════════════════════════════════════════
# Main
# ════════════════════════════════════════════════════════════════
check_requirements
CHALLENGER_ADDR=$(cast wallet address "$CHALLENGER_KEY")

# Parse args
WATCH_MODE=false
DO_RESOLVE=false
INTERVAL=30
GAME_INDEX=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch)
            WATCH_MODE=true
            shift
            ;;
        --resolve)
            DO_RESOLVE=true
            shift
            ;;
        --interval)
            INTERVAL="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [[ -z "$GAME_INDEX" ]] && [[ "$1" =~ ^[0-9]+$ ]]; then
                GAME_INDEX="$1"
            fi
            shift
            ;;
    esac
done

if [[ "$WATCH_MODE" == "true" ]]; then
    watch_mode "$INTERVAL" "$DO_RESOLVE"
    exit 0
fi

# ════════════════════════════════════════════════════════════════
# Single game mode
# ════════════════════════════════════════════════════════════════
if [[ -z "$GAME_INDEX" ]]; then
    usage
fi

echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}${BOLD}  TEE Dispute Game Challenger${NC}"
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

if challenge_game "$GAME_ADDR" "$GAME_INDEX"; then
    if [[ "$DO_RESOLVE" == "true" ]]; then
        resolve_game "$GAME_ADDR" "$GAME_INDEX"
    fi
fi

echo ""
echo -e "${GREEN}${BOLD}Done.${NC}"
