#!/bin/bash

# ═══════════════════════════════════════════════════════════════════════════════
# Kailua Test Fault - Launch malicious challenge using kailua-cli test-fault
# ═══════════════════════════════════════════════════════════════════════════════
source ../.env

# Configuration (modify according to your environment)
L1_RPC=${L1_RPC:-"http://localhost:8545"}
L1_BEACON=${L1_BEACON:-"http://localhost:3500"}
L2_RPC=${L2_RPC:-"http://localhost:8123"}
OP_NODE=${OP_NODE:-"http://localhost:9545"}
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

# Show all games
show_games() {
    TOTAL=$(cast call $DISPUTE_GAME_FACTORY_ADDRESS "gameCount()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}                           Kailua Games (Total: $TOTAL)                            ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Idx   Type  L2Block     Status          Parent  Children  ProofStatus"
    echo "────  ────  ──────────  ──────────────  ──────  ────────  ───────────"
    
    for i in $(seq 0 $((TOTAL-1))); do
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
        
        # Get parent index
        parentIdx=$(cast call $gameAddr "parentGameIndex()(uint64)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
        if [ -z "$parentIdx" ] || [ "$parentIdx" = "" ]; then
            parentIdx="anchor"
            proofStatusStr="-"
            proofClr="${NC}"
        else
            # Get this game's signature
            signature=$(cast call $gameAddr "signature()(bytes32)" --rpc-url $L1_RPC 2>/dev/null)
            
            # Get parent game's address
            parentInfo=$(cast call $DISPUTE_GAME_FACTORY_ADDRESS "gameAtIndex(uint256)(uint32,uint64,address)" $parentIdx --rpc-url $L1_RPC 2>/dev/null)
            parentAddr=$(echo "$parentInfo" | tail -1)
            
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
        
        printf "%4d  %4d  %10d  ${clr}%-14s${NC}  %6s  %8d  ${proofClr}%-11s${NC}\n" \
            $i "$gameType" "$l2Block" "$statusStr" "$parentIdx" "$childCount" "$proofStatusStr"
    done
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
    echo ""
    echo "This will create a new faulty proposal as a sibling of Game $target_idx,"
    echo "both extending from Parent Game $parentIdx."
    echo ""
    
    read -p "Enter fault-offset (1-10, default=1): " OFFSET
    OFFSET=${OFFSET:-1}
    
    echo ""
    echo -e "${YELLOW}Executing: kailua-cli test-fault --fault-parent $parentIdx --fault-offset $OFFSET${NC}"
    echo ""
    
    # Check if kailua-cli exists
    if ! command -v kailua-cli &> /dev/null; then
        echo -e "${RED}Error: kailua-cli not found in PATH${NC}"
        echo ""
        echo "Please build and install it:"
        echo "  cd /Users/oker/rust-workspace/kailua"
        echo "  RISC0_SKIP_BUILD_KERNELS=1 cargo build --bin kailua-cli --release"
        echo "  sudo cp target/release/kailua-cli /usr/local/bin/"
        return 1
    fi
    
    # Execute test-fault
    RUST_LOG=info RISC0_DEV_MODE=1 kailua-cli test-fault \
        --eth-rpc-url $L1_RPC \
        --beacon-rpc-url $L1_BEACON \
        --op-geth-url $L2_RPC \
        --op-node-url $OP_NODE \
        --proposer-key $ATTACKER_KEY \
        --fault-offset $OFFSET \
        --fault-parent $parentIdx \
        --txn-timeout 300
        # --exec-gas-premium 5000 \
        # --blob-gas-premium 5000 \
        
    
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
    echo "Configuration:"
    echo "  L1 RPC:     $L1_RPC"
    echo "  L1 Beacon:  $L1_BEACON"
    echo "  L2 RPC:     $L2_RPC"
    echo "  OP Node:    $OP_NODE"
    echo "  Factory:    $DISPUTE_GAME_FACTORY_ADDRESS"
    echo "  Attacker:   $(cast wallet address $ATTACKER_KEY 2>/dev/null)"
    
    show_games
    
    echo "Commands:"
    echo "  <idx>    - Challenge game at index <idx>"
    echo "  d <idx>  - Show detailed info for game <idx>"
    echo "  r        - Refresh game list"
    echo "  q        - Quit"
    echo ""
    nc -z localhost 8545 && echo "eth OK" || (echo "eth NOT running" && exit 1)
    nc -z localhost 3500 && echo "beacon OK" || (echo "beacon NOT running" && exit 1)
    nc -z localhost 8123 && echo "l2 OK" || (echo "l2 NOT running" && exit 1)
    nc -z localhost 9545 && echo "op-node OK" || (echo "op-node NOT running" && exit 1)
    
    while true; do
        read -p "Enter command (idx/d idx/r/q): " input
        
        # Parse command
        cmd=$(echo "$input" | awk '{print $1}')
        arg=$(echo "$input" | awk '{print $2}')
        
        case "$cmd" in
            q|Q|quit|exit)
                echo "Bye!"
                exit 0
                ;;
            r|R|refresh)
                show_games
                ;;
            d|D|detail)
                if [ -n "$arg" ] && [[ "$arg" =~ ^[0-9]+$ ]]; then
                    show_game_detail $arg
                else
                    echo -e "${RED}Usage: d <game_index>${NC}"
                fi
                ;;
            ''|*[!0-9]*)
                echo -e "${RED}Invalid input. Enter a number, 'd <idx>', 'r', or 'q'.${NC}"
                ;;
            *)
                do_challenge $cmd
                echo ""
                echo "─────────────────────────────────────────────────────────────────────"
                read -p "Press Enter to continue..."
                show_games
                ;;
        esac
    done
}

main

