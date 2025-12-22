#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source ../.env

if [ -n "$OP_GETH_LOCAL_DIRECTORY" ]; then
    # Use local directory
    OP_GETH_PATH="$OP_GETH_LOCAL_DIRECTORY"
    BRANCH_TO_USE="$OP_GETH_BRANCH"
    REPO_TYPE="op-geth"
    
    if [ ! -d "$OP_GETH_PATH" ]; then
        echo "Error: op-geth directory not found at: $OP_GETH_PATH"
        exit 1
    fi
    
    echo "Using op-geth from: $OP_GETH_PATH"
    
elif [ -n "$OP_STACK_LOCAL_DIRECTORY" ]; then
    # Use local op-stack submodule
    OP_GETH_PATH="$OP_STACK_LOCAL_DIRECTORY/op-geth"
    BRANCH_TO_USE="$OP_STACK_BRANCH"
    REPO_TYPE="op-stack"
    REPO_ROOT="$OP_STACK_LOCAL_DIRECTORY"
    
    if [ ! -d "$OP_GETH_PATH" ]; then
        echo "Error: op-geth directory not found at: $OP_GETH_PATH"
        echo "Make sure OP_STACK_LOCAL_DIRECTORY points to your optimism repository"
        exit 1
    fi
    
    echo "Using op-geth from op-stack submodule: $OP_GETH_PATH"
    
else
    echo "Error: No op-geth path configured"
    echo ""
    echo "Please set one of the following in devnet/.env:"
    echo "  OP_GETH_LOCAL_DIRECTORY=/path/to/op-geth"
    echo "  OP_STACK_LOCAL_DIRECTORY=/path/to/optimism"
    exit 1
fi

# Handle branch checkout based on repository type
if [ -n "$BRANCH_TO_USE" ]; then
    echo "Switching to branch: $BRANCH_TO_USE"
    
    if [ "$REPO_TYPE" = "op-stack" ]; then
        CHECKOUT_DIR="$REPO_ROOT"
    else
        CHECKOUT_DIR="$OP_GETH_PATH"
    fi
    
    cd "$CHECKOUT_DIR" && git fetch origin && git checkout "$BRANCH_TO_USE" && git pull origin "$BRANCH_TO_USE"
fi

echo "Updating go.mod..."

OP_GETH_TEST_DIR="$SCRIPT_DIR/../op-geth"
cd "$OP_GETH_TEST_DIR" || exit 1
go mod edit -replace "github.com/ethereum/go-ethereum=$OP_GETH_PATH"
go mod tidy

echo "go.mod configured successfully"
echo ""
echo "Replace directive: github.com/ethereum/go-ethereum => $OP_GETH_PATH"

