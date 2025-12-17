#!/bin/bash

# ═══════════════════════════════════════════════════════════════════════════════
# Kailua Test Fault - Launch malicious challenge using kailua-cli test-fault
# Uses Docker container to run kailua-cli
# ═══════════════════════════════════════════════════════════════════════════════

# Parse arguments
STATS_MODE="none"
START_GAME=""
END_GAME=""

if [ $# -eq 0 ]; then
    STATS_MODE="none"
elif [ $# -eq 2 ]; then
    START_GAME=$1
    END_GAME=$2
    
    # Validate arguments
    if ! [[ "$START_GAME" =~ ^[0-9]+$ ]] || ! [[ "$END_GAME" =~ ^[0-9]+$ ]]; then
        echo "Error: Arguments must be numbers"
        echo ""
        echo "Usage: $0 [START_IDX END_IDX]"
        echo ""
        echo "Examples:"
        echo "  $0           # List all games with block ranges (fast)"
        echo "  $0 10 13     # Analyze games 10-13 with transaction stats"
        exit 1
    fi
    
    if [ $START_GAME -gt $END_GAME ]; then
        echo "Error: START_IDX must be <= END_IDX"
        exit 1
    fi
    
    STATS_MODE="range"
else
    echo "Usage: $0 [START_IDX END_IDX]"
    echo ""
    echo "Examples:"
    echo "  $0           # List all games with block ranges (fast)"
    echo "  $0 10 13     # Analyze games 10-13 with transaction stats"
    exit 1
fi

source ../.env

# Docker configuration
KAILUA_IMAGE_TAG=${KAILUA_IMAGE_TAG:-"kailua:latest"}
DOCKER_NETWORK=${DOCKER_NETWORK:-"dev-op"}

# Host RPC URLs (for cast commands run on host)
L1_RPC=${L1_RPC_URL:-"http://localhost:8545"}
L1_BEACON=${L1_BEACON_URL:-"http://localhost:3500"}
L2_RPC=${L2_RPC_URL:-"http://localhost:8123"}
OP_NODE=${L2_NODE_RPC_URL:-"http://localhost:9545"}

# Docker RPC URLs (for kailua-cli inside container)
L1_RPC_URL_IN_DOCKER=${L1_RPC_URL_IN_DOCKER:-"http://l1-geth:8545"}
L1_BEACON_URL_IN_DOCKER=${L1_BEACON_URL_IN_DOCKER:-"http://l1-beacon-chain:3500"}
L2_RPC_URL_IN_DOCKER=${L2_RPC_URL_IN_DOCKER:-"http://op-geth-seq:8545"}
L2_NODE_RPC_URL_IN_DOCKER=${L2_NODE_RPC_URL_IN_DOCKER:-"http://op-seq:9545"}

ATTACKER_KEY=${ATTACKER_KEY:-"0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"}
DISPUTE_GAME_FACTORY_ADDRESS=${DISPUTE_GAME_FACTORY_ADDRESS:-"0xd43adf4c4338ae8b6ca3e76779bcec9971f7996f"}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Status names
status_name() {
    case $1 in
        0) echo "IN_PROGRESS" ;;
        1) echo "CHALLENGER" ;;
        2) echo "DEFENDER" ;;
        *) echo "?" ;;
    esac
}

# ProofStatus names
proof_status_name() {
    case $1 in
        0) echo "NONE" ;;
        1) echo "FAULT" ;;
        2) echo "VALID" ;;
        *) echo "?" ;;
    esac
}

# ProofStatus colors
proof_status_color() {
    case $1 in
        0) echo "${NC}" ;;      # NONE - default color
        1) echo "${RED}" ;;     # FAULT - red
        2) echo "${GREEN}" ;;   # VALID - green
        *) echo "${NC}" ;;
    esac
}

# Count transactions in block range
count_transactions() {
    local startBlock=$1
    local endBlock=$2
    local total=0
    
    local block=$startBlock
    while [ $block -lt $endBlock ]; do
        # Convert to hex using bc to avoid scientific notation
        local hexBlock=$(echo "obase=16; $block" | bc)
        
        # Get transaction count
        local txNum=$(cast rpc eth_getBlockByNumber "0x$hexBlock" false --rpc-url $L2_RPC 2>/dev/null | jq -r '.transactions | length // 0')
        
        # Validate and add
        if [[ "$txNum" =~ ^[0-9]+$ ]]; then
            total=$((total + txNum))
        fi
        
        block=$((block + 1))
    done
    
    echo "$total"
}

# Format number with comma separator
format_number() {
    printf "%'d" $1 2>/dev/null || echo $1
}

# Show all games
show_games() {
    TOTAL=$(cast call $DISPUTE_GAME_FACTORY_ADDRESS "gameCount()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
    
    # Determine scan range
    local SCAN_START=0
    local SCAN_END=-1  # Default: don't scan any games
    
    if [ "$STATS_MODE" = "range" ]; then
        SCAN_START=$START_GAME
        SCAN_END=$END_GAME
    fi
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════════════════${NC}"
    if [ "$STATS_MODE" = "range" ]; then
        echo -e "${BLUE}                     Kailua Games $START_GAME-$END_GAME (Total: $TOTAL)                     ${NC}"
    else
        echo -e "${BLUE}                              Kailua Games (Total: $TOTAL)                                  ${NC}"
    fi
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Idx   Type  L2Block     Status          Parent  Children  BlockRange        TxCount    ProofStatus"
    echo "────  ────  ──────────  ──────────────  ──────  ────────  ────────────────  ─────────  ───────────"
    
    local totalTxs=0
    local scannedBlocks=0
    local maxTxGame=-1
    local maxTxCount=0
    
    # Store game data for display
    declare -a gameData
    
    for i in $(seq 0 $((TOTAL-1))); do
        # Skip games outside range when in range mode
        if [ "$STATS_MODE" = "range" ]; then
            if [ $i -lt $START_GAME ] || [ $i -gt $END_GAME ]; then
                continue
            fi
        fi
        
        gameInfo=$(cast call $DISPUTE_GAME_FACTORY_ADDRESS "gameAtIndex(uint256)(uint32,uint64,address)" $i --rpc-url $L1_RPC 2>/dev/null)
        gameType=$(echo "$gameInfo" | head -1)
        gameAddr=$(echo "$gameInfo" | tail -1)
        
        # Only show Kailua games (1337)
        if [ "$gameType" != "1337" ]; then
            continue
        fi
        
        l2Block=$(cast call $gameAddr "l2BlockNumber()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
        statusCode=$(cast call $gameAddr "status()(uint8)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
        statusStr=$(status_name $statusCode)
        childCount=$(cast call $gameAddr "childCount()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
        
        # Get parent index and calculate block range
        parentIdx=$(cast call $gameAddr "parentGameIndex()(uint64)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
        if [ -z "$parentIdx" ] || [ "$parentIdx" = "" ]; then
            parentIdx="anchor"
            proofStatusStr="-"
            proofClr="${NC}"
            parentL2Block=0
            blockRange="0-$l2Block"
        else
            # Get this game's signature
            signature=$(cast call $gameAddr "signature()(bytes32)" --rpc-url $L1_RPC 2>/dev/null)
            
            # Get parent game's address
            parentInfo=$(cast call $DISPUTE_GAME_FACTORY_ADDRESS "gameAtIndex(uint256)(uint32,uint64,address)" $parentIdx --rpc-url $L1_RPC 2>/dev/null)
            parentAddr=$(echo "$parentInfo" | tail -1)
            
            # Get parent L2 block
            parentL2Block=$(cast call $parentAddr "l2BlockNumber()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
            blockRange="$parentL2Block-$l2Block"
            
            # Query proofStatus
            if [ -n "$parentAddr" ] && [ -n "$signature" ]; then
                proofStatusCode=$(cast call $parentAddr "proofStatus(bytes32)(uint8)" $signature --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
                proofStatusStr=$(proof_status_name $proofStatusCode)
                proofClr=$(proof_status_color $proofStatusCode)
            else
                proofStatusStr="-"
                proofClr="${NC}"
            fi
        fi
        
        # Status color
        case $statusCode in
            0) clr="${YELLOW}" ;;
            2) clr="${GREEN}" ;;
            *) clr="${RED}" ;;
        esac
        
        # Count transactions if in scan range
        txCountStr="-"
        txCount=0
        if [ $i -ge $SCAN_START ] && [ $i -le $SCAN_END ]; then
            # Show progress
            current=$((i - SCAN_START + 1))
            total=$((SCAN_END - SCAN_START + 1))
            echo -ne "\r${CYAN}[Scanning $current/$total: Game $i]${NC}\033[K"
            
            # Count transactions
            txCount=$(count_transactions $parentL2Block $l2Block)
            txCountStr=$(format_number $txCount)
            totalTxs=$((totalTxs + txCount))
            scannedBlocks=$((scannedBlocks + l2Block - parentL2Block))
            
            # Track max
            if [ $txCount -gt $maxTxCount ]; then
                maxTxCount=$txCount
                maxTxGame=$i
            fi
            
            # Clear progress line
            echo -ne "\r\033[K"
        fi
        
        # Store game data for later display
        gameData[$i]="$i|$gameType|$l2Block|$statusStr|$clr|$parentIdx|$childCount|$blockRange|$txCountStr|$txCount|$proofStatusStr|$proofClr"
    done
    
    # Display all stored games with proper star marking
    for idx in "${!gameData[@]}"; do
        IFS='|' read -r i gameType l2Block statusStr clr parentIdx childCount blockRange txCountStr txCount proofStatusStr proofClr <<< "${gameData[$idx]}"
        
        # Add star marker for max tx game
        if [ "$idx" = "$maxTxGame" ] && [ $txCount -gt 0 ]; then
            printf "%4d  %4d  %10d  ${clr}%-14s${NC}  %6s  %8d  %-16s  %-9s ★  ${proofClr}%-11s${NC}\n" \
                "$i" "$gameType" "$l2Block" "$statusStr" "$parentIdx" "$childCount" "$blockRange" "$txCountStr" "$proofStatusStr"
        else
            printf "%4d  %4d  %10d  ${clr}%-14s${NC}  %6s  %8d  %-16s  %-9s    ${proofClr}%-11s${NC}\n" \
                "$i" "$gameType" "$l2Block" "$statusStr" "$parentIdx" "$childCount" "$blockRange" "$txCountStr" "$proofStatusStr"
        fi
    done
    
    # Summary
    echo ""
    if [ "$STATS_MODE" = "none" ]; then
        echo -e "${GREEN}Game list loaded.${NC}"
        echo ""
        echo -e "${CYAN}💡 To see transaction statistics, run:${NC}"
        echo -e "${CYAN}   $0 START_IDX END_IDX${NC}"
    else
        scannedGames=$((SCAN_END - SCAN_START + 1))
        echo -e "${GREEN}Analysis complete!${NC} (Scanned $scannedGames games, $(format_number $scannedBlocks) blocks, $(format_number $totalTxs) total txs)"
        
        if [ $maxTxGame -ge 0 ]; then
            echo -e "${YELLOW}★${NC} Game $maxTxGame has the highest transaction count ($(format_number $maxTxCount) txs)"
            echo "  Recommended for stress testing"
        fi
    fi
    echo ""
}

# Show detailed info for a single game
show_game_detail() {
    local idx=$1
    
    gameInfo=$(cast call $DISPUTE_GAME_FACTORY_ADDRESS "gameAtIndex(uint256)(uint32,uint64,address)" $idx --rpc-url $L1_RPC 2>/dev/null)
    if [ -z "$gameInfo" ]; then
        echo -e "${RED}Error: Game $idx not found${NC}"
        return 1
    fi
    
    gameType=$(echo "$gameInfo" | head -1)
    gameAddr=$(echo "$gameInfo" | tail -1)
    
    if [ "$gameType" != "1337" ]; then
        echo -e "${RED}Error: Game $idx is not a Kailua game (type=$gameType)${NC}"
        return 1
    fi
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    Game $idx Details                              ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    echo -e "Address:        ${YELLOW}$gameAddr${NC}"
    
    l2Block=$(cast call $gameAddr "l2BlockNumber()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
    echo -e "L2 Block:       $l2Block"
    
    statusCode=$(cast call $gameAddr "status()(uint8)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
    statusStr=$(status_name $statusCode)
    echo -e "Status:         $statusStr ($statusCode)"
    
    signature=$(cast call $gameAddr "signature()(bytes32)" --rpc-url $L1_RPC 2>/dev/null)
    echo -e "Signature:      $signature"
    
    rootClaim=$(cast call $gameAddr "rootClaim()(bytes32)" --rpc-url $L1_RPC 2>/dev/null)
    echo -e "Root Claim:     $rootClaim"
    
    childCount=$(cast call $gameAddr "childCount()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
    echo -e "Children:       $childCount"
    
    parentIdx=$(cast call $gameAddr "parentGameIndex()(uint64)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
    if [ -z "$parentIdx" ] || [ "$parentIdx" = "" ]; then
        echo -e "Parent:         ${MAGENTA}anchor (Treasury)${NC}"
        echo -e "Proof Status:   -"
    else
        echo -e "Parent Index:   $parentIdx"
        
        # Get parent address and query proofStatus
        parentInfo=$(cast call $DISPUTE_GAME_FACTORY_ADDRESS "gameAtIndex(uint256)(uint32,uint64,address)" $parentIdx --rpc-url $L1_RPC 2>/dev/null)
        parentAddr=$(echo "$parentInfo" | tail -1)
        echo -e "Parent Address: $parentAddr"
        
        if [ -n "$parentAddr" ] && [ -n "$signature" ]; then
            proofStatusCode=$(cast call $parentAddr "proofStatus(bytes32)(uint8)" $signature --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
            proofStatusStr=$(proof_status_name $proofStatusCode)
            proofClr=$(proof_status_color $proofStatusCode)
            echo -e "Proof Status:   ${proofClr}$proofStatusStr ($proofStatusCode)${NC}"
            
            # If proof exists, show prover and provenAt
            if [ "$proofStatusCode" != "0" ]; then
                prover=$(cast call $parentAddr "prover(bytes32)(address)" $signature --rpc-url $L1_RPC 2>/dev/null)
                provenAt=$(cast call $parentAddr "provenAt(bytes32)(uint64)" $signature --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
                echo -e "Prover:         $prover"
                echo -e "Proven At:      $provenAt"
            fi
        fi
    fi
    
    echo ""
}

# Launch challenge
do_challenge() {
    local target_idx=$1
    
    # Get target game info
    gameInfo=$(cast call $DISPUTE_GAME_FACTORY_ADDRESS "gameAtIndex(uint256)(uint32,uint64,address)" $target_idx --rpc-url $L1_RPC 2>/dev/null)
    if [ -z "$gameInfo" ]; then
        echo -e "${RED}Error: Game $target_idx not found${NC}"
        return 1
    fi
    
    gameType=$(echo "$gameInfo" | head -1)
    if [ "$gameType" != "1337" ]; then
        echo -e "${RED}Error: Game $target_idx is not a Kailua game (type=$gameType)${NC}"
        return 1
    fi
    
    targetAddr=$(echo "$gameInfo" | tail -1)
    
    # Get parent index
    parentIdx=$(cast call $targetAddr "parentGameIndex()(uint64)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
    if [ -z "$parentIdx" ] || [ "$parentIdx" = "" ]; then
        echo -e "${RED}Error: Game $target_idx is the anchor (Treasury), cannot challenge${NC}"
        return 1
    fi
    
    # Get current game count (new game's index)
    currentCount=$(cast call $DISPUTE_GAME_FACTORY_ADDRESS "gameCount()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
    
    targetL2=$(cast call $targetAddr "l2BlockNumber()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
    
    echo ""
    echo -e "${RED}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}                    MALICIOUS CHALLENGE                             ${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "Target Game:      ${YELLOW}$target_idx${NC} (L2=$targetL2)"
    echo -e "Target's Parent:  ${YELLOW}$parentIdx${NC}"
    echo -e "New Game Index:   ${GREEN}$currentCount${NC} (will be created)"
    echo -e "Fault Offset:     ${CYAN}1${NC} (auto)"
    echo ""
    echo "This will create a new faulty proposal as a sibling of Game $target_idx,"
    echo "both extending from Parent Game $parentIdx."
    echo ""
    
    # Auto-set fault-offset to 1
    OFFSET=1
    
    echo -e "${YELLOW}Executing via Docker: kailua-cli test-fault --fault-parent $parentIdx --fault-offset $OFFSET${NC}"
    echo ""
    
    # Execute test-fault using Docker
    docker run --rm \
        --network "$DOCKER_NETWORK" \
        -e RUST_LOG=info \
        -e RISC0_DEV_MODE=1 \
        -e EXEC_GAS_PREMIUM=100000 \
        -e BLOB_GAS_PREMIUM=100000 \
        "$KAILUA_IMAGE_TAG" \
        kailua-cli \
        test-fault \
        --eth-rpc-url "$L1_RPC_URL_IN_DOCKER" \
        --beacon-rpc-url "$L1_BEACON_URL_IN_DOCKER" \
        --op-geth-url "$L2_RPC_URL_IN_DOCKER" \
        --op-node-url "$L2_NODE_RPC_URL_IN_DOCKER" \
        --proposer-key "$ATTACKER_KEY" \
        --fault-offset "$OFFSET" \
        --fault-parent "$parentIdx" \
        --txn-timeout 300
    
    if [ $? -eq 0 ]; then
        echo ""
        echo -e "${GREEN}✅ Malicious proposal submitted!${NC}"
        echo -e "New Game Index: ${GREEN}$currentCount${NC}"
        echo ""
        echo "Game $parentIdx now has 2+ children:"
        echo "  - Game $target_idx (original, correct)"
        echo "  - Game $currentCount (new, faulty)"
    else
        echo ""
        echo -e "${RED}❌ Failed to submit malicious proposal${NC}"
    fi
}

# Main program
main() {
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║          Kailua Malicious Challenge Tool (test-fault)             ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Check services (silent unless error)
    nc -z localhost 8545 2>/dev/null || (echo -e "${RED}✗ Error: L1 RPC (localhost:8545) NOT running${NC}" && exit 1)
    nc -z localhost 3500 2>/dev/null || (echo -e "${RED}✗ Error: L1 Beacon (localhost:3500) NOT running${NC}" && exit 1)
    nc -z localhost 8123 2>/dev/null || (echo -e "${RED}✗ Error: L2 RPC (localhost:8123) NOT running${NC}" && exit 1)
    nc -z localhost 9545 2>/dev/null || (echo -e "${RED}✗ Error: OP Node (localhost:9545) NOT running${NC}" && exit 1)
    
    # Get game count
    TOTAL_GAMES=$(cast call $DISPUTE_GAME_FACTORY_ADDRESS "gameCount()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
    echo "Found ${GREEN}$TOTAL_GAMES${NC} Kailua games."
    echo ""
    
    # Show mode-specific tips
    if [ "$STATS_MODE" = "none" ]; then
        echo -e "${CYAN}💡 Tip: To analyze transaction statistics, specify a game range:${NC}"
        echo -e "${CYAN}   Usage: $0 START_IDX END_IDX${NC}"
        echo -e "${CYAN}   Example: $0 10 13${NC}"
        echo ""
        echo "Loading game list (showing block ranges only)..."
    else
        echo -e "${CYAN}📊 Analyzing games $START_GAME-$END_GAME with transaction statistics...${NC}"
        echo "(Only showing specified range)"
    fi
    
    show_games
    
    read -p "Enter game index to challenge: " game_idx
    
    # Validate input
    if [ -z "$game_idx" ]; then
        echo -e "${RED}Error: No index provided${NC}"
        exit 1
    fi
    
    if ! [[ "$game_idx" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: Invalid index. Must be a number.${NC}"
        exit 1
    fi
    
    do_challenge $game_idx
}

main
