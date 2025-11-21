#!/bin/bash

# set -x
set -e

BRANCH_NAME=${1:-""}
PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ ! -f .env ] && cp example.env .env

source .env

if [ "$SKIP_OP_STACK_BUILD" = "true" ]; then
    echo "⏭️  Skipping op-stack build"
else
    if [ "$OP_STACK_LOCAL_DIRECTORY" = "" ]; then
        echo "❌ Please set OP_STACK_LOCAL_DIRECTORY in .env"
        exit 1
    else
        echo "🔨 Building op-stack"
        cd "$OP_STACK_LOCAL_DIRECTORY"
        docker build -t "$OP_STACK_IMAGE_TAG" -f ./Dockerfile-opstack .
    fi
fi

if [ "$SKIP_OP_GETH_BUILD" = "true" ]; then
    echo "⏭️  Skipping op-geth build"
else
    # Set OP_GETH_LOCAL_DIRECTORY if not set
    if [ "$OP_GETH_LOCAL_DIRECTORY" = "" ]; then
        cd "$OP_STACK_LOCAL_DIRECTORY"
        git submodule update --init --recursive
        OP_GETH_DIR="$OP_STACK_LOCAL_DIRECTORY/op-geth"
        echo "📍 Using op-geth submodule of op-stack"
    else
        OP_GETH_DIR="$OP_GETH_LOCAL_DIRECTORY"
        echo "📍 Using op-geth local directory: $OP_GETH_LOCAL_DIRECTORY"
    fi

    # Switch to specified branch if provided
    if [ -n "$OP_GETH_BRANCH" ]; then
        echo "🔄 Switching op-geth to branch: $OP_GETH_BRANCH"
        cd "$OP_GETH_DIR"
        git fetch origin
        git checkout "$OP_GETH_BRANCH"
        git pull origin "$OP_GETH_BRANCH"
        cd "$PWD_DIR"
    else
        echo "📍 Using op-geth default branch"
    fi

    echo "🔨 Building $OP_GETH_IMAGE_TAG"
    cd "$OP_GETH_DIR"
    docker build -t "$OP_GETH_IMAGE_TAG" .
fi

# Build OP_CONTRACTS image if not skipping
if [ "$SKIP_OP_CONTRACTS_BUILD" = "true" ]; then
    echo "⏭️  Skipping op-contracts build"
else
    if [ "$OP_STACK_LOCAL_DIRECTORY" = "" ]; then
        echo "❌ Please set OP_STACK_LOCAL_DIRECTORY in .env"
        exit 1
    else
        echo "🔨 Building $OP_CONTRACTS_IMAGE_TAG..."
        cd "$OP_STACK_LOCAL_DIRECTORY"
        docker build -t "$OP_CONTRACTS_IMAGE_TAG" -f ./Dockerfile-contracts .
    fi
fi

# Build OP_RETH image if not skipping
if [ "$SKIP_OP_RETH_BUILD" = "true" ]; then
    echo "⏭️  Skipping op-reth build"
else
    if [ "$OP_RETH_LOCAL_DIRECTORY" = "" ]; then
        echo "❌ Please set OP_RETH_LOCAL_DIRECTORY in .env"
        exit 1
    else
        echo "🔨 Building $OP_RETH_IMAGE_TAG"
        cd "$OP_RETH_LOCAL_DIRECTORY"
        if [ -n "$OP_RETH_BRANCH" ]; then
            echo "🔄 Switching op-reth to branch: $OP_RETH_BRANCH"
            git fetch origin
            git checkout "$OP_RETH_BRANCH"
            git pull origin "$OP_RETH_BRANCH"
        else
            echo "📍 Using op-reth branch: $(git branch --show-current)"
        fi
        docker build -t "$OP_RETH_IMAGE_TAG" -f ./DockerfileOp .
        cd "$OP_STACK_LOCAL_DIRECTORY"
    fi
fi

# Build OP_SUCCINCT image if not skipping
if [ "$SKIP_OP_SUCCINCT_BUILD" = "true" ]; then
    echo "⏭️  Skipping op-succinct build"
else
    if [ "$OP_SUCCINCT_DIRECTORY" = "" ]; then
        echo "❌ Please set OP_SUCCINCT_DIRECTORY in .env"
        exit 1
    else
        cd "$OP_SUCCINCT_DIRECTORY"

        echo "🔨 Building $OP_SUCCINCT_CONTRACTS_IAMGE_TAG"
        
        # Copy custom deployment scripts to op-succinct (will be cleaned after build)
        mkdir -p "$OP_SUCCINCT_DIRECTORY/deployment"
        cp "$PWD_DIR/op-succinct/deployment/"*.sol "$OP_SUCCINCT_DIRECTORY/deployment/" 2>/dev/null || true
        
        docker build -t "$OP_SUCCINCT_CONTRACTS_IAMGE_TAG" -f "$PWD_DIR/op-succinct/Dockerfile.contract" "$OP_SUCCINCT_DIRECTORY"
        
        # Clean up custom scripts from op-succinct to keep it pristine
        rm -rf "$OP_SUCCINCT_DIRECTORY/deployment"

        echo "🔨 Building $OP_SUCCINCT_PROPOSER_IMAGE_TAG"
        docker build -t "$OP_SUCCINCT_PROPOSER_IMAGE_TAG" -f ./fault-proof/Dockerfile.proposer .

        echo "🔨 Building $OP_SUCCINCT_CHALLENGER_IMAGE_TAG"
        docker build -t "$OP_SUCCINCT_CHALLENGER_IMAGE_TAG" -f ./fault-proof/Dockerfile.challenger .
    fi
fi