#!/bin/bash
# OP-Succinct Challenge Manager
# List and manually challenge dispute games

set -e

# ════════════════════════════════════════════════════════════════
# Configuration
# ════════════════════════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVNET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment variables
[ -f "$DEVNET_DIR/.env" ] && source "$DEVNET_DIR/.env"

FACTORY_ADDRESS=${DISPUTE_GAME_FACTORY_ADDRESS:-""}
L1_RPC=${L1_RPC_URL:-"http://localhost:8545"}
L2_RPC=${L2_RPC_URL:-"http://localhost:9545"}
CHALLENGER_KEY=${CHALLENGER_PRIVATE_KEY:-""}
GAME_TYPE=42  # OP-Succinct game type
PROPOSAL_INTERVAL=${PROPOSAL_INTERVAL_IN_BLOCKS:-10}  # Blocks per proposal

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ════════════════════════════════════════════════════════════════
# Helper Functions
# ════════════════════════════════════════════════════════════════

check_requirements() {
    if ! command -v cast &> /dev/null; then
        echo -e "${RED}Error: 'cast' not found. Install Foundry: https://getfoundry.sh${NC}"
        exit 1
    fi
    
    if [ -z "$FACTORY_ADDRESS" ]; then
        echo -e "${RED}Error: DISPUTE_GAME_FACTORY_ADDRESS not set in $DEVNET_DIR/.env${NC}"
        exit 1
    fi
}

# Count transactions in block range (fast, includes system txs)
count_transactions() {
    local start=$1 end=$2 total=0
    for ((block=start; block<=end; block++)); do
        local count=$(cast block $block --rpc-url $L2_RPC --json 2>/dev/null | jq '.transactions | length' 2>/dev/null || echo "0")
        total=$((total + count))
    done
    echo "$total"
}

# Analyze transaction types (slower, detailed)
analyze_transactions() {
    local start=$1 end=$2
    local native=0 erc20=0 contract=0 system=0
    
    for ((block=start; block<=end; block++)); do
        local txs=$(cast block $block --rpc-url $L2_RPC --json 2>/dev/null | jq -r '.transactions[]?' 2>/dev/null || echo "")
        [ -z "$txs" ] && continue
        
        while IFS= read -r tx; do
            [ -z "$tx" ] && continue
            local tx_data=$(cast tx $tx --rpc-url $L2_RPC --json 2>/dev/null || echo '{}')
            local from=$(echo "$tx_data" | jq -r '.from // "0x0"')
            local input=$(echo "$tx_data" | jq -r '.input // "0x"')
            
            # System transaction
            if [[ "$from" == *"dead"* ]] || [[ "$from" == *"Dead"* ]]; then
                system=$((system + 1))
            # Native transfer
            elif [ "$input" = "0x" ]; then
                native=$((native + 1))
            # ERC20 transfer (0xa9059cbb)
            elif [[ "$input" == 0xa9059cbb* ]]; then
                erc20=$((erc20 + 1))
            # Contract call
            else
                contract=$((contract + 1))
            fi
        done <<< "$txs"
    done
    
    echo "$native,$erc20,$contract,$system"
}

# ════════════════════════════════════════════════════════════════
# Main Functions
# ════════════════════════════════════════════════════════════════

list_games() {
    local detail=${1:-false}
    
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  OP-Succinct Dispute Games (Type $GAME_TYPE)${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local total=$(cast call $FACTORY_ADDRESS "gameCount()(uint256)" --rpc-url $L1_RPC 2>/dev/null)
    
    if [ -z "$total" ] || [ "$total" = "0" ]; then
        echo -e "${YELLOW}No games found.${NC}"
        return
    fi
    
    echo -e "${CYAN}Total Games: $total${NC}"
    echo -e "${YELLOW}Loading game details...${NC}"
    echo ""
    
    # Table header
    printf "${BOLD}%-6s %-8s %-25s %-10s %-10s %-20s %-20s${NC}\n" \
        "Index" "Type" "Block Range" "Blocks" "Txs" "Status" "Proof"
    echo "──────────────────────────────────────────────────────────────────────────────────────────"
    
    local count=0
    
    # Iterate through all games
    for ((i=0; i<total; i++)); do
        local game_data=$(cast call $FACTORY_ADDRESS "gameAtIndex(uint256)((uint32,uint64,address))" $i --rpc-url $L1_RPC 2>/dev/null)
        [ -z "$game_data" ] && continue
        
        # Parse: (type, timestamp, address)
        local type=$(echo "$game_data" | grep -oE '\([0-9]+' | head -1 | tr -d '(')
        local addr=$(echo "$game_data" | grep -oE '0x[a-fA-F0-9]{40}')
        
        # Only show OP-Succinct games
        [ "$type" != "$GAME_TYPE" ] && continue
        
        count=$((count + 1))
        
        # Get game details
        local start=$(cast call $addr "l2BlockNumber()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
        [ -z "$start" ] && start=0
        local end=$((start + PROPOSAL_INTERVAL - 1))
        local blocks=$PROPOSAL_INTERVAL
        local txs=$(count_transactions $start $end)
        
        # Get status (5th field in claimData: parentIndex, counteredBy, prover, claim, status, deadline)
        local claim_hex=$(cast call $addr "claimData()" --rpc-url $L1_RPC 2>/dev/null)
        # Extract 5th field (bytes 128-160): skip 2 (0x) + 64*4 = 258 chars, take next 64 chars
        local status_hex="0x$(echo "$claim_hex" | cut -c259-322)"
        local status=$(cast --to-dec "$status_hex" 2>/dev/null || echo "0")
        
        # Format status
        local status_text proof_text
        case $status in
            0) status_text="Unchallenged" proof_text="N/A" ;;
            1) status_text="Challenged" proof_text="Pending" ;;
            2) status_text="Unchal+Proof" proof_text="Valid" ;;
            3) status_text="Chal+Proof" proof_text="Valid" ;;
            4) status_text="Resolved" proof_text="Done" ;;
            *) status_text="Unknown($status)" proof_text="?" ;;
        esac
        
        printf "%-6s %-8s %-25s %-10s %-10s %-20s %-20s\n" \
            "$i" "$type" "$start-$end" "$blocks" "$txs" "$status_text" "$proof_text"
    done
    
    echo ""
    echo -e "${CYAN}OP-Succinct Games: $count${NC}"
    echo ""
}

analyze_game() {
    local idx=$1
    
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  Game Analysis: #$idx${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local game_data=$(cast call $FACTORY_ADDRESS "gameAtIndex(uint256)((uint32,uint64,address))" $idx --rpc-url $L1_RPC 2>/dev/null)
    
    if [ -z "$game_data" ]; then
        echo -e "${RED}Error: Game #$idx not found${NC}"
        return 1
    fi
    
    # Parse: (type, timestamp, address)
    local type=$(echo "$game_data" | grep -oE '\([0-9]+' | head -1 | tr -d '(')
    local addr=$(echo "$game_data" | grep -oE '0x[a-fA-F0-9]{40}')
    
    echo -e "${BOLD}Address:${NC} $addr"
    echo -e "${BOLD}Type:${NC} $type"
    
    if [ "$type" != "$GAME_TYPE" ]; then
        echo -e "${YELLOW}⚠️  Not an OP-Succinct game (expected type $GAME_TYPE)${NC}"
        return 1
    fi
    
    # Get block range
    local start=$(cast call $addr "l2BlockNumber()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
    [ -z "$start" ] && start=0
    local end=$((start + PROPOSAL_INTERVAL - 1))
    local blocks=$PROPOSAL_INTERVAL
    
    echo -e "${BOLD}Block Range:${NC} $start - $end ($blocks blocks)"
    echo ""
    
    # Get status (5th field in claimData)
    local claim_hex=$(cast call $addr "claimData()" --rpc-url $L1_RPC 2>/dev/null)
    local status_hex="0x$(echo "$claim_hex" | cut -c259-322)"
    local status=$(cast --to-dec "$status_hex" 2>/dev/null || echo "0")
    
    # Decode status
    local status_desc
    case $status in
        0) status_desc="Unchallenged" ;;
        1) status_desc="Challenged (proof pending)" ;;
        2) status_desc="Unchallenged but valid proof provided" ;;
        3) status_desc="Challenged and valid proof provided (defender wins)" ;;
        4) status_desc="Resolved" ;;
        *) status_desc="Unknown ($status)" ;;
    esac
    
    echo -e "${BOLD}Status:${NC} $status_desc"
    echo ""
    
    # Analyze transactions
    echo -e "${BOLD}Analyzing transactions...${NC}"
    local analysis=$(analyze_transactions $start $end)
    IFS=',' read -r native erc20 contract system <<< "$analysis"
    local total=$((native + erc20 + contract))
    
    echo ""
    echo -e "${BOLD}Transaction Breakdown:${NC}"
    echo "────────────────────────────────────────────────────────────────"
    printf "  %-20s ${GREEN}%s${NC}\n" "Native Transfers:" "$native"
    printf "  %-20s ${CYAN}%s${NC}\n" "ERC20 Transfers:" "$erc20"
    printf "  %-20s ${BLUE}%s${NC}\n" "Contract Calls:" "$contract"
    printf "  %-20s ${YELLOW}%s${NC}\n" "System Txs:" "$system"
    printf "  %-20s ${BOLD}%s${NC}\n" "Total User Txs:" "$total"
    echo ""
    
    # Estimate PROVE cost
    echo -e "${BOLD}Estimated PROVE Cost:${NC}"
    echo "────────────────────────────────────────────────────────────────"
    
    local base=0.2
    local block_cost=$(echo "$blocks * 0.1" | bc)
    local tx_cost=$(echo "$native * 0.010 + $erc20 * 0.012 + $contract * 0.018" | bc)
    local total_cost=$(echo "$base + $block_cost + $tx_cost" | bc)
    
    printf "  %-25s %s PROVE\n" "Base Fee:" "0.2"
    printf "  %-25s %s PROVE\n" "Block Cost:" "$block_cost"
    printf "  %-25s %s PROVE\n" "Transaction Cost:" "$tx_cost"
    echo "  ─────────────────────────────────────────────"
    printf "  %-25s ${YELLOW}~%s PROVE${NC}\n" "Estimated Total:" "$total_cost"
    echo ""
    
    # Recommendation
    if [ $total -ge 50 ] && [ $total -le 200 ]; then
        echo -e "${GREEN}✅ Good candidate for testing (balanced workload)${NC}"
    elif [ $total -lt 10 ]; then
        echo -e "${YELLOW}⚠️  Low transaction count${NC}"
    elif [ $total -gt 500 ]; then
        echo -e "${YELLOW}⚠️  High transaction count (may exceed gas limit)${NC}"
    fi
    
    [ "$status" != "0" ] && echo -e "${YELLOW}⚠️  Already challenged (status: $status)${NC}"
    
    echo ""
}

challenge_game() {
    local idx=$1
    
    [ -z "$CHALLENGER_KEY" ] && { echo -e "${RED}Error: CHALLENGER_PRIVATE_KEY not set${NC}"; return 1; }
    
    # Get game address
    local game_data=$(cast call $FACTORY_ADDRESS "gameAtIndex(uint256)((uint32,uint64,address))" $idx --rpc-url $L1_RPC 2>/dev/null)
    local addr=$(echo "$game_data" | grep -oE '0x[a-fA-F0-9]{40}')
    
    [ -z "$addr" ] && { echo -e "${RED}Game #$idx not found${NC}"; return 1; }
    
    # Get required bond
    local bond=$(cast call $addr "challengerBond()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
    [ -z "$bond" ] && bond="1000000000000000"  # Default: 0.001 ETH
    
    echo ""
    echo -e "${CYAN}Challenging game #$idx ($addr)...${NC}"
    
    # Send challenge transaction with bond
    local result=$(cast send $addr "challenge()" --value $bond --private-key $CHALLENGER_KEY --rpc-url $L1_RPC --json 2>&1)
    local exit_code=$?
    
    # Extract TX hash
    local tx=$(echo "$result" | jq -r '.transactionHash' 2>/dev/null)
    
    # Check if successful
    if [ $exit_code -ne 0 ] || [ -z "$tx" ] || [ "$tx" = "null" ]; then
        echo -e "${RED}❌ Failed${NC}"
        echo -e "${YELLOW}Error: $result${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Success! TX: $tx${NC}"
    echo -e "${YELLOW}Monitor: docker logs -f op-succinct-proposer${NC}"
    echo ""
}


# ════════════════════════════════════════════════════════════════
# Interactive Mode
# ════════════════════════════════════════════════════════════════

interactive_mode() {
    check_requirements
    
    # Show configuration
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  OP-Succinct Challenge Manager${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Factory:${NC} $FACTORY_ADDRESS"
    echo -e "  ${BOLD}L1 RPC:${NC} $L1_RPC"
    echo -e "  ${BOLD}L2 RPC:${NC} $L2_RPC"
    echo -e "  ${BOLD}Game Type:${NC} $GAME_TYPE (OP-Succinct)"
    echo -e "  ${BOLD}Proposal Interval:${NC} $PROPOSAL_INTERVAL blocks"
    echo ""
    
    # Show game list
    list_games
    
    # Prompt for challenge
    echo ""
    echo -n "Enter game index (or press ENTER to exit): "
    read -r idx
    
    # Exit if empty
    [ -z "$idx" ] && { echo ""; exit 0; }
    
    # Challenge
    challenge_game "$idx"
}

# ════════════════════════════════════════════════════════════════
# Main Entry Point
# ════════════════════════════════════════════════════════════════

if [ $# -eq 0 ]; then
    interactive_mode
else
    check_requirements
    
    case "$1" in
        list)
            list_games
            ;;
        analyze)
            [ -z "$2" ] && { echo "Usage: $0 analyze <index>"; exit 1; }
            analyze_game "$2"
            ;;
        challenge)
            [ -z "$2" ] && { echo "Usage: $0 challenge <index>"; exit 1; }
            challenge_game "$2"
            ;;
        *)
            echo "Usage: $0 [COMMAND] [ARGS]"
            echo ""
            echo "Commands:"
            echo "  list              List all games"
            echo "  analyze <index>   Analyze game details"
            echo "  challenge <index> Challenge a game"
            echo ""
            echo "Interactive mode: $0"
            exit 1
            ;;
    esac
fi

