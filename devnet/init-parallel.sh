#!/bin/bash
# Fully parallel build script - all four images build simultaneously

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

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ ! -f .env ] && cp example.env .env

source .env

VERBOSE=false
if [ "$1" = "-v" ]; then
  VERBOSE=true
fi

if [ "$OP_STACK_LOCAL_DIRECTORY" = "" ]; then
  echo "❌ Please set OP_STACK_LOCAL_DIRECTORY in .env"
  exit 1
fi

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

# Set up op-reth if not skipping
if [ "$SKIP_OP_RETH_BUILD" != "true" ]; then
  if [ "$OP_RETH_LOCAL_DIRECTORY" = "" ]; then
    echo "❌ Please set OP_RETH_LOCAL_DIRECTORY in .env"
    exit 1
  else
    OP_RETH_DIR="$OP_RETH_LOCAL_DIRECTORY"
    if [ -n "$OP_RETH_BRANCH" ]; then
      echo "🔄 Switching op-reth to branch: $OP_RETH_BRANCH"
      cd "$OP_RETH_DIR"
      git fetch origin
      git checkout "$OP_RETH_BRANCH"
      git pull origin "$OP_RETH_BRANCH"
      cd -
    else
      echo "📍 Using op-reth branch: $(cd "$OP_RETH_DIR" && git branch --show-current)"
      cd $PWD_DIR
    fi
  fi
fi

cd "$OP_STACK_LOCAL_DIRECTORY"
git submodule update --init --recursive
cd -

# Create log directory
mkdir -p /tmp/docker-build-logs

echo "================================================"
echo "FULLY PARALLEL BUILD MODE"
echo "================================================"
echo "Building op-geth, op-contracts, op-stack, and op-reth simultaneously"
echo "================================================"
echo ""

# Track PIDs for parallel builds
BUILD_PIDS=()
TAIL_PIDS=()

function build_and_tag_image() {
  local image_base_name=$1
  local image_tag=$2
  local build_dir=$3
  local dockerfile=$4

  cd "$build_dir"
  GITTAG=$(git rev-parse --short HEAD)
  START_TIME=$(date +%s)

  echo "🔨 Building ${image_base_name}..."
  docker build -t "${image_base_name}:${GITTAG}" -f "$dockerfile" . \
    > /tmp/docker-build-logs/${image_base_name}.log 2>&1 && \
    docker tag "${image_base_name}:${GITTAG}" "${image_tag}" && \
    echo "✅ Built and tagged image: ${image_base_name}:${GITTAG} as ${image_tag}" &
  PID=$!
  BUILD_PIDS+=("$PID:${image_base_name}:$START_TIME")
  ALL_PIDS+=($PID)

  if $VERBOSE; then
    tail -f /tmp/docker-build-logs/${image_base_name}.log 2>/dev/null | sed "s/^/[${image_base_name}] /" &
    TAIL_PID=$!
    TAIL_PIDS+=($TAIL_PID)
    ALL_PIDS+=($TAIL_PID)
  fi
  cd -
}

# Start all builds in parallel
echo "🚀 Starting parallel builds..."

# Build OP_CONTRACTS in background
if [ "$SKIP_OP_CONTRACTS_BUILD" = "true" ]; then
  echo "⏭️  Skipping op-contracts build"
else
  echo "🔨 [1/4] Starting op-contracts build..."
  build_and_tag_image "op-contracts" "$OP_CONTRACTS_IMAGE_TAG" "$OP_STACK_LOCAL_DIRECTORY" "Dockerfile-contracts"
fi

# Build OP_GETH in background
if [ "$SKIP_OP_GETH_BUILD" = "true" ]; then
  echo "⏭️  Skipping op-geth build"
else
  echo "🔨 [2/4] Starting op-geth build..."
  build_and_tag_image "op-geth" "$OP_GETH_IMAGE_TAG" "$OP_GETH_DIR" "Dockerfile"
fi

# Build OP_STACK in background
if [ "$SKIP_OP_STACK_BUILD" = "true" ]; then
  echo "⏭️  Skipping op-stack build"
else
  if [ "$OP_STACK_LOCAL_DIRECTORY" = "" ]; then
    echo "❌ Please set OP_STACK_LOCAL_DIRECTORY in .env"
    exit 1
  fi
  echo "🔨 [3/4] Starting op-stack build..."
  build_and_tag_image "op-stack" "$OP_STACK_IMAGE_TAG" "$OP_STACK_LOCAL_DIRECTORY" "Dockerfile-opstack"
fi

# Build OP_RETH in background
if [ "$SKIP_OP_RETH_BUILD" = "true" ]; then
  echo "⏭️  Skipping op-reth build"
else
  if [ "$OP_RETH_LOCAL_DIRECTORY" = "" ]; then
    echo "❌ Please set OP_RETH_LOCAL_DIRECTORY in .env"
    exit 1
  fi
  echo "🔨 [4/4] Starting op-reth build..."
  build_and_tag_image "op-reth" "$OP_RETH_IMAGE_TAG" "$OP_RETH_LOCAL_DIRECTORY" "DockerfileOp"
fi

# Wait for all builds to complete
if [ ${#BUILD_PIDS[@]} -gt 0 ]; then
  if $VERBOSE; then
    echo ""
    echo "Building in parallel... (live output below)"
    echo "================================================"
    echo ""
  fi

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
        elif [ "$name" = "op-reth" ] && [ -z "$RETH_END" ]; then
          RETH_END=$(date +%s)
          RETH_TIME=$((RETH_END - start_time))
        fi
      fi
    done

    if $all_done; then
      break
    fi

    sleep 1
  done

  # Re-enable debug output
  # set -x

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

  if [ -n "$RETH_END" ]; then
    reth_min=$((RETH_TIME / 60))
    reth_sec=$((RETH_TIME % 60))
    echo "✅ op-reth: Success (${reth_min}m ${reth_sec}s)"
  elif [ "$SKIP_OP_RETH_BUILD" != "true" ]; then
    echo "❌ op-reth: Failed"
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
docker images | grep -E "(op-geth|op-stack|op-contracts|op-reth)" | grep -v "<none>" || echo "No images found"
echo ""
echo "================================================"
