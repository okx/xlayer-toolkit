#!/bin/bash
# Fully parallel build script - all three images build simultaneously

set -x
set -e

# Record start time
START_TIME=$(date +%s)

# Track all background PIDs for cleanup
ALL_PIDS=()

# Cleanup function to kill all background processes
cleanup() {
    echo ""
    echo "================================================"
    echo "Caught interrupt signal, cleaning up..."
    echo "================================================"

    # Kill all tracked processes and their children
    for pid in "${ALL_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "Killing process $pid and its children..."
            # Try to kill process group first (for docker build and its children)
            kill -- -$pid 2>/dev/null || kill "$pid" 2>/dev/null || true
        fi
    done

    # Give processes time to terminate gracefully
    sleep 2

    # Force kill any remaining processes
    for pid in "${ALL_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "Force killing process $pid..."
            kill -9 -- -$pid 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
        fi
    done

    echo "Cleanup complete. All build processes terminated."
    exit 1
}

# Set up trap to catch Ctrl+C (SIGINT) and SIGTERM
trap cleanup SIGINT SIGTERM

BRANCH_NAME=${1:-""}
PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPTIMISM_DIR=$(git rev-parse --show-toplevel)

[ ! -f .env ] && cp example.env .env

source .env

if [ "$OP_GETH_LOCAL_DIRECTORY" = "" ]; then
    git submodule update --init --recursive
    OP_GETH_DIR="$OPTIMISM_DIR/op-geth"
else
    OP_GETH_DIR="$OP_GETH_LOCAL_DIRECTORY"
fi

# Switch to specified branch if provided
if [ -n "$BRANCH_NAME" ]; then
    echo "Switching op-geth to branch: $BRANCH_NAME"
    cd $OP_GETH_DIR
    git fetch origin
    git checkout "$BRANCH_NAME"
    git pull origin "$BRANCH_NAME"
    cd "$PWD_DIR"
else
    echo "Using op-geth default branch"
fi

# TODO: need to further confirm why it fails if we do not add require in this contract
cp $PWD_DIR/contracts/Transactor.sol $OPTIMISM_DIR/packages/contracts-bedrock/src/periphery/Transactor.sol

cd $OPTIMISM_DIR

# Create log directory
mkdir -p /tmp/docker-build-logs

echo "================================================"
echo "FULLY PARALLEL BUILD MODE"
echo "================================================"
echo "Building op-geth, op-contracts, and op-stack simultaneously"
echo "================================================"
echo ""

# Track PIDs for parallel builds
BUILD_PIDS=()
TAIL_PIDS=()

# Start all builds in parallel
echo "Starting parallel builds..."

# Build OP_CONTRACTS in background
if [ $SKIP_OP_CONTRACTS_BUILD = "true" ]; then
    echo "Skipping op-contracts build"
else
    echo "[1/3] Starting op-contracts build..."
    CONTRACTS_START=$(date +%s)

    docker build -t $OP_CONTRACTS_IMAGE_TAG -f ./Dockerfile-contracts . > /tmp/docker-build-logs/op-contracts.log 2>&1 &
    CONTRACTS_PID=$!
    BUILD_PIDS+=("$CONTRACTS_PID:op-contracts:$CONTRACTS_START")
    ALL_PIDS+=($CONTRACTS_PID)

    tail -f /tmp/docker-build-logs/op-contracts.log 2>/dev/null | sed 's/^/[op-contracts] /' &
    TAIL_CONTRACTS_PID=$!
    TAIL_PIDS+=($TAIL_CONTRACTS_PID)
    ALL_PIDS+=($TAIL_CONTRACTS_PID)
fi

# Build OP_GETH in background
if [ $SKIP_OP_GETH_BUILD = "true" ]; then
    echo "Skipping op-geth build"
else
    echo "[2/3] Starting op-geth build..."
    GETH_START=$(date +%s)

    cd $OP_GETH_DIR
    docker build -t $OP_GETH_IMAGE_TAG . > /tmp/docker-build-logs/op-geth.log 2>&1 &
    GETH_PID=$!
    BUILD_PIDS+=("$GETH_PID:op-geth:$GETH_START")
    ALL_PIDS+=($GETH_PID)

    tail -f /tmp/docker-build-logs/op-geth.log 2>/dev/null | sed 's/^/[op-geth] /' &
    TAIL_GETH_PID=$!
    TAIL_PIDS+=($TAIL_GETH_PID)
    ALL_PIDS+=($TAIL_GETH_PID)

    cd $OPTIMISM_DIR
fi

# Build OP_STACK in background
if [ $SKIP_OP_STACK_BUILD = "true" ]; then
    echo "Skipping op-stack build"
else
    echo "[3/3] Starting op-stack build..."
    STACK_START=$(date +%s)

    docker build -t $OP_STACK_IMAGE_TAG -f ./Dockerfile-opstack . > /tmp/docker-build-logs/op-stack.log 2>&1 &
    STACK_PID=$!
    BUILD_PIDS+=("$STACK_PID:op-stack:$STACK_START")
    ALL_PIDS+=($STACK_PID)

    tail -f /tmp/docker-build-logs/op-stack.log 2>/dev/null | sed 's/^/[op-stack] /' &
    TAIL_STACK_PID=$!
    TAIL_PIDS+=($TAIL_STACK_PID)
    ALL_PIDS+=($TAIL_STACK_PID)
fi

# Wait for all builds to complete
if [ ${#BUILD_PIDS[@]} -gt 0 ]; then
    echo ""
    echo "Building in parallel... (live output below)"
    echo "================================================"
    echo ""

    # Disable debug output for monitoring loop to reduce noise
    set +x

    # Monitor loop to record exact completion time for each build
    while true; do
        all_done=true

        for pid_info in "${BUILD_PIDS[@]}"; do
            IFS=':' read -r pid name start_time <<< "$pid_info"

            # Check if process is still running
            if kill -0 "$pid" 2>/dev/null; then
                all_done=false
            else
                # Process finished, record time if not already recorded
                if [ "$name" = "op-contracts" ] && [ -z "$CONTRACTS_END" ]; then
                    CONTRACTS_END=$(date +%s)
                    CONTRACTS_TIME=$((CONTRACTS_END - start_time))
                elif [ "$name" = "op-geth" ] && [ -z "$GETH_END" ]; then
                    GETH_END=$(date +%s)
                    GETH_TIME=$((GETH_END - start_time))
                elif [ "$name" = "op-stack" ] && [ -z "$STACK_END" ]; then
                    STACK_END=$(date +%s)
                    STACK_TIME=$((STACK_END - start_time))
                fi
            fi
        done

        if $all_done; then
            break
        fi

        sleep 1
    done

    # Re-enable debug output
    set -x

    # Now wait for exit codes
    FAILED=0
    for pid_info in "${BUILD_PIDS[@]}"; do
        IFS=':' read -r pid name start_time <<< "$pid_info"

        wait "$pid"
        exit_code=$?

        if [ $exit_code -ne 0 ]; then
            FAILED=1
        fi
    done

    # Stop all tail processes
    for tail_pid in "${TAIL_PIDS[@]}"; do
        kill $tail_pid 2>/dev/null || true
    done

    # Give tail processes a moment to finish
    sleep 1

    echo ""
    echo "================================================"
    echo "BUILD RESULTS"
    echo "================================================"

    # Display results for each build
    if [ -n "$CONTRACTS_END" ]; then
        contracts_min=$((CONTRACTS_TIME / 60))
        contracts_sec=$((CONTRACTS_TIME % 60))
        echo "✅ op-contracts: Success (${contracts_min}m ${contracts_sec}s)"
    elif [ "$SKIP_OP_CONTRACTS_BUILD" != "true" ]; then
        echo "❌ op-contracts: Failed"
    fi

    if [ -n "$GETH_END" ]; then
        geth_min=$((GETH_TIME / 60))
        geth_sec=$((GETH_TIME % 60))
        echo "✅ op-geth: Success (${geth_min}m ${geth_sec}s)"
    elif [ "$SKIP_OP_GETH_BUILD" != "true" ]; then
        echo "❌ op-geth: Failed"
    fi

    if [ -n "$STACK_END" ]; then
        stack_min=$((STACK_TIME / 60))
        stack_sec=$((STACK_TIME % 60))
        echo "✅ op-stack: Success (${stack_min}m ${stack_sec}s)"
    elif [ "$SKIP_OP_STACK_BUILD" != "true" ]; then
        echo "❌ op-stack: Failed"
    fi

    if [ $FAILED -ne 0 ]; then
        echo ""
        echo "ERROR: Some builds failed. Check logs at /tmp/docker-build-logs/"
        exit 1
    fi
fi

# Calculate total time (from start to end)
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))
TOTAL_MIN=$((TOTAL_TIME / 60))
TOTAL_SEC=$((TOTAL_TIME % 60))

echo ""
echo "================================================"
echo "BUILD COMPLETE"
echo "================================================"
echo "Total time: ${TOTAL_MIN}m ${TOTAL_SEC}s"
echo ""
echo "Built images:"
docker images | grep -E "(op-geth|op-stack|op-contracts)" | grep latest
echo ""
echo "================================================"
