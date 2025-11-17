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

        # Check if profiling is enabled and build accordingly
        if [ "$RETH_PROFILING_ENABLED" = "true" ]; then
            echo "Building with profiling support..."
            cd $PWD_DIR
            ./scripts/build-reth-with-profiling.sh
        else
            echo "Building standard op-reth image..."
            docker build -t $OP_RETH_IMAGE_TAG -f ./DockerfileOp .
        fi

        cd "$OP_STACK_LOCAL_DIRECTORY"
    fi
fi

# Build adventure binary if not skipping
if [ "$SKIP_ADVENTURE_BUILD" = "true" ]; then
    echo "⏭️  Skipping adventure build"
else
    if [ "$ADVENTURE_LOCAL_DIRECTORY" = "" ]; then
        echo "❌ Please set ADVENTURE_LOCAL_DIRECTORY in .env"
        exit 1
    else
        echo "🔨 Building adventure binary"
        cd "$ADVENTURE_LOCAL_DIRECTORY"

        # Switch to specified branch if provided
        if [ -n "$ADVENTURE_BRANCH" ]; then
            echo "🔄 Switching adventure to branch: $ADVENTURE_BRANCH"
            git fetch origin
            git checkout "$ADVENTURE_BRANCH"
            git pull origin "$ADVENTURE_BRANCH"
        else
            echo "📍 Using adventure branch: $(git branch --show-current)"
        fi

        # Build the Go binary with optimization flags
        echo "🔨 Building Go binary with optimizations..."
        go build -ldflags="-s -w" -o adventure

        # Copy binary to /usr/local/bin
        echo "📦 Installing binary to /usr/local/bin..."
        sudo cp adventure /usr/local/bin/
        sudo chmod +x /usr/local/bin/adventure

        # Add /usr/local/bin to PATH if not already present
        if [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then
            export PATH="/usr/local/bin:$PATH"
            echo "✅ Added /usr/local/bin to PATH"
        fi

        echo "✅ Adventure binary installed successfully"
        cd "$PWD_DIR"
    fi
fi
