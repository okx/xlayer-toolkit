#!/bin/bash

# set -x
set -e

BRANCH_NAME=${1:-""}
PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ ! -f .env ] && cp example.env .env

source .env

function build_and_tag_image() {
  local image_base_name=$1
  local image_tag=$2
  local build_dir=$3
  local dockerfile=$4

  cd "$build_dir"
  GITTAG=$(git rev-parse --short HEAD)
  docker build -t "${image_base_name}:${GITTAG}" -f "$dockerfile" .
  docker tag "${image_base_name}:${GITTAG}" "${image_tag}"
  echo "✅ Built and tagged image: ${image_base_name}:${GITTAG} as ${image_tag}"
  cd -
}

# Build OP_STACK image
if [ "$SKIP_OP_STACK_BUILD" = "true" ]; then
  echo "⏭️  Skipping op-stack build"
else
  if [ "$OP_STACK_LOCAL_DIRECTORY" = "" ]; then
    echo "❌ Please set OP_STACK_LOCAL_DIRECTORY in .env"
    exit 1
  else
    echo "🔨 Building op-stack"
    cd "$OP_STACK_LOCAL_DIRECTORY"
    git submodule update --init --recursive
    cd -
    build_and_tag_image "op-stack" "$OP_STACK_IMAGE_TAG" "$OP_STACK_LOCAL_DIRECTORY" "Dockerfile-opstack"
  fi
fi

# Build OP_GETH image
if [ "$SKIP_OP_GETH_BUILD" = "true" ]; then
  echo "⏭️  Skipping op-geth build"
else
  # Set OP_GETH_LOCAL_DIRECTORY if not set
  if [ "$OP_GETH_LOCAL_DIRECTORY" = "" ]; then
    cd "$OP_STACK_LOCAL_DIRECTORY"
    git submodule update --init --recursive
    OP_GETH_DIR="$OP_STACK_LOCAL_DIRECTORY/op-geth"
    echo "📍 Using op-geth submodule of op-stack"
    cd -
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
    cd -
  else
    echo "📍 Using op-geth default branch"
  fi

  echo "🔨 Building $OP_GETH_IMAGE_TAG"
  build_and_tag_image "op-geth" "$OP_GETH_IMAGE_TAG" "$OP_GETH_DIR" "Dockerfile"
fi

# Build OP_CONTRACTS image
if [ "$SKIP_OP_CONTRACTS_BUILD" = "true" ]; then
  echo "⏭️  Skipping op-contracts build"
else
  if [ "$OP_STACK_LOCAL_DIRECTORY" = "" ]; then
    echo "❌ Please set OP_STACK_LOCAL_DIRECTORY in .env"
    exit 1
  else
    echo "🔨 Building $OP_CONTRACTS_IMAGE_TAG..."
    cd "$OP_STACK_LOCAL_DIRECTORY"
    git submodule update --init --recursive
    cd -
    build_and_tag_image "op-contracts" "$OP_CONTRACTS_IMAGE_TAG" "$OP_STACK_LOCAL_DIRECTORY" "Dockerfile-contracts"
  fi
fi

# Build OP_RETH image
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
    cd -

    # Check if profiling is enabled and build accordingly
    if [ "$RETH_PROFILING_ENABLED" = "true" ]; then
      echo "Building with profiling support..."
      cd $PWD_DIR
      ./scripts/build-reth-with-profiling.sh
    else
      echo "Building standard op-reth image..."
      build_and_tag_image "op-reth" "$OP_RETH_IMAGE_TAG" "$OP_RETH_LOCAL_DIRECTORY" "DockerfileOp"
    fi

    cd "$OP_STACK_LOCAL_DIRECTORY"
  fi
fi

# Build OP_SUCCINCT image if not skipping
if [ "$SKIP_OP_SUCCINCT_BUILD" = "true" ]; then
  echo "⏭️  Skipping op-succinct build"
else
  if [ "$OP_SUCCINCT_LOCAL_DIRECTORY" = "" ]; then
    echo "❌ Please set OP_SUCCINCT_LOCAL_DIRECTORY in .env"
    exit 1
  else
    echo "🔨 Building op-succinct images"

    cd "$OP_SUCCINCT_LOCAL_DIRECTORY"
    build_and_tag_image "op-succinct" "$OP_SUCCINCT_IMAGE_TAG" "$OP_SUCCINCT_LOCAL_DIRECTORY" "Dockerfile"
    build_and_tag_image "op-succinct-contracts" "$OP_SUCCINCT_CONTRACTS_IMAGE_TAG" "$OP_SUCCINCT_LOCAL_DIRECTORY" "Dockerfile.contract"
  fi
fi

# Build Kailua image
if [ "$SKIP_KAILUA_BUILD" = "true" ]; then
  echo "⏭️  Skipping kailua build"
else
  if [ "$KAILUA_LOCAL_DIRECTORY" = "" ]; then
    echo "❌ Please set KAILUA_LOCAL_DIRECTORY in .env"
    exit 1
  else
    echo "🔨 Building kailua image"
    
    cd "$KAILUA_LOCAL_DIRECTORY"
    build_and_tag_image "kailua" "$KAILUA_IMAGE_TAG" "$KAILUA_LOCAL_DIRECTORY" "Dockerfile.local"
  fi
fi

# Build RAILGUN images (using devnet-managed Dockerfiles)

if [ "$SKIP_RAILGUN_CONTRACT_BUILD" = "true" ]; then
  echo "⏭️  Skipping RAILGUN contract build"
else
  if [ -z "$RAILGUN_CONTRACT_DIRECTORY" ]; then
    echo "❌ Please set RAILGUN_CONTRACT_DIRECTORY in .env"
    exit 1
  fi
  
  if [ ! -d "$RAILGUN_CONTRACT_DIRECTORY" ]; then
    echo "❌ Contract directory not found: $RAILGUN_CONTRACT_DIRECTORY"
    exit 1
  fi
  
  echo "🔨 Building RAILGUN contract image from: $RAILGUN_CONTRACT_DIRECTORY"
  # Copy devnet-managed Dockerfile (fixes yarn vs npm issue)
  cp "$PWD_DIR/railgun/Dockerfile.contract" "$RAILGUN_CONTRACT_DIRECTORY/Dockerfile.devnet"
  docker build -t "$RAILGUN_CONTRACT_IMAGE_TAG" -f "$RAILGUN_CONTRACT_DIRECTORY/Dockerfile.devnet" "$RAILGUN_CONTRACT_DIRECTORY"
  rm -f "$RAILGUN_CONTRACT_DIRECTORY/Dockerfile.devnet"
  echo "✅ Built RAILGUN contract image: $RAILGUN_CONTRACT_IMAGE_TAG"
fi

if [ "$SKIP_RAILGUN_POI_BUILD" = "true" ]; then
  echo "⏭️  Skipping RAILGUN POI node build"
else
  if [ -z "$RAILGUN_POI_DIRECTORY" ]; then
    echo "❌ Please set RAILGUN_POI_DIRECTORY in .env"
    exit 1
  fi
  
  if [ ! -d "$RAILGUN_POI_DIRECTORY" ]; then
    echo "⚠️  Warning: POI directory not found: $RAILGUN_POI_DIRECTORY, skipping"
  else
    echo "🔨 Building RAILGUN POI node image from: $RAILGUN_POI_DIRECTORY"
    # Copy devnet-managed Dockerfile
    cp "$PWD_DIR/railgun/Dockerfile.poi-node" "$RAILGUN_POI_DIRECTORY/Dockerfile.devnet"
    docker build -t "$RAILGUN_POI_IMAGE_TAG" -f "$RAILGUN_POI_DIRECTORY/Dockerfile.devnet" "$RAILGUN_POI_DIRECTORY"
    rm -f "$RAILGUN_POI_DIRECTORY/Dockerfile.devnet"
    echo "✅ Built RAILGUN POI node image: $RAILGUN_POI_IMAGE_TAG"
  fi
fi

if [ "$SKIP_RAILGUN_BROADCASTER_BUILD" = "true" ]; then
  echo "⏭️  Skipping RAILGUN broadcaster build"
else
  if [ -z "$RAILGUN_BROADCASTER_DIRECTORY" ]; then
    echo "❌ Please set RAILGUN_BROADCASTER_DIRECTORY in .env"
    exit 1
  fi
  
  RAILGUN_BROADCASTER_DIR="$RAILGUN_BROADCASTER_DIRECTORY/docker"
  if [ ! -d "$RAILGUN_BROADCASTER_DIR" ]; then
    echo "⚠️  Warning: Broadcaster directory not found: $RAILGUN_BROADCASTER_DIR, skipping"
  else
    echo "🔨 Building RAILGUN broadcaster image from: $RAILGUN_BROADCASTER_DIR"
    # Broadcaster has its own build.sh script which requires .env file
    cd "$RAILGUN_BROADCASTER_DIR"
    
    # Create .env from devnet-managed template
    echo "   Creating .env from devnet template for build..."
    cp "$PWD_DIR/railgun/example.env.broadcaster-build" .env
    
    ./build.sh --no-swag
    cd "$PWD_DIR"
    echo "✅ Built RAILGUN broadcaster image"
  fi
fi
