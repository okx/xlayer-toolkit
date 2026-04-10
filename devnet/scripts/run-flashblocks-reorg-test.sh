#!/bin/bash
set -e

# Flashblocks Reorg Test Runner
# This script orchestrates the full flashblocks reorg test:
# 1. Starts devnet with conductor enabled
# 2. Waits for all services to be running
# 3. Stops op-seq3 and op-geth-seq3 containers
# 4. Runs the flashblock reorg monitoring test (using 8124 RPC node)
# 5. Runs the transfer leader test to trigger failovers
#
# NOTE: To generate transactions during the test, run the adventure ERC20 stress
# test separately. Before running, update the RPC endpoint in
# tools/adventure/testdata/config.json to use port 8124:
#   "rpc": ["http://127.0.0.1:8124"]
# Then run: cd tools/adventure && make erc20

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVNET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Track background PIDs for cleanup
REORG_TEST_PID=""
TRANSFER_LEADER_PID=""
CLEANING_UP=false

cleanup() {
    # Prevent re-entry from repeated Ctrl+C
    if [ "$CLEANING_UP" = true ]; then
        return
    fi
    CLEANING_UP=true

    # Disable set -e so cleanup runs fully even if commands fail
    set +e

    # Ignore further signals during cleanup
    trap '' INT TERM

    echo ""
    echo ">>> Cleaning up background processes..."

    # Stop transfer leader test
    if [ -n "$TRANSFER_LEADER_PID" ] && kill -0 "$TRANSFER_LEADER_PID" 2>/dev/null; then
        echo "  Stopping test_transfer_leader.sh (PID $TRANSFER_LEADER_PID) and children..."
        pkill -P "$TRANSFER_LEADER_PID" 2>/dev/null
        kill "$TRANSFER_LEADER_PID" 2>/dev/null
        wait "$TRANSFER_LEADER_PID" 2>/dev/null
    fi

    # Stop flashblock reorg test (SIGINT for graceful shutdown / summary)
    if [ -n "$REORG_TEST_PID" ] && kill -0 "$REORG_TEST_PID" 2>/dev/null; then
        echo "  Stopping test_flashblock_reorg.py (PID $REORG_TEST_PID)..."
        kill -SIGINT "$REORG_TEST_PID" 2>/dev/null
        wait "$REORG_TEST_PID" 2>/dev/null
    fi

    echo "  All background processes stopped."
    exit 1
}

trap cleanup EXIT INT TERM

# Helper: launch a background process and verify it's still alive after a delay
launch_and_verify() {
    local name=$1
    local pid=$2
    local wait_secs=${3:-3}

    sleep "$wait_secs"
    if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" 2>/dev/null
        local exit_code=$?
        echo "  ERROR: $name (PID $pid) exited immediately with code $exit_code"
        exit 1
    fi
    echo "  $name (PID $pid) is running."
}

echo "============================================"
echo "  Flashblocks Reorg Test Runner"
echo "============================================"
echo ""

# --- Step 1: Start devnet with conductor enabled ---
echo ">>> Step 1: Starting devnet with conductor enabled..."
cd "$DEVNET_DIR"

# Enable conductor in .env
sed -i.bak 's/^CONDUCTOR_ENABLED=.*/CONDUCTOR_ENABLED=true/' .env
rm -f .env.bak
echo "  Set CONDUCTOR_ENABLED=true in .env"

make run
echo "  Devnet started."
echo ""

# --- Step 2: Wait for all services to be running ---
echo ">>> Step 2: Waiting for all services to be running..."

MAX_WAIT=180
elapsed=0
echo "  Waiting for RPC at http://localhost:8124 ..."
while [ $elapsed -lt $MAX_WAIT ]; do
    result=$(curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        "http://localhost:8124" 2>/dev/null | jq -r .result 2>/dev/null || echo "")
    if [ -n "$result" ] && [ "$result" != "null" ] && [ "$result" != "" ]; then
        block_num=$((16#${result#0x}))
        if [ "$block_num" -gt 0 ]; then
            echo "  RPC is responding (block #$block_num)"
            break
        fi
    fi
    sleep 3
    elapsed=$((elapsed + 3))
done

if [ $elapsed -ge $MAX_WAIT ]; then
    echo "  ERROR: RPC not responding within ${MAX_WAIT}s"
    exit 1
fi
echo "  All services are running."
echo ""

# --- Step 3: Stop op-seq3 and op-geth-seq3 ---
echo ">>> Step 3: Stopping op-seq3 and op-geth-seq3..."
docker stop op-seq3
docker stop op-geth-seq3
echo "  Stopped op-seq3 and op-geth-seq3."
echo ""

# --- Step 4: Run flashblock reorg test in the background ---
echo ">>> Step 4: Setting up Python venv and starting flashblock reorg monitoring test..."

# Find Python >= 3.12, or install it via pyenv if not available.
PYTHON_BIN=""
MIN_PYTHON_MINOR=12  # 3.12+

# Check system python3 first
if command -v python3 &>/dev/null; then
    py_major=$(python3 -c "import sys; print(sys.version_info.major)" 2>/dev/null || echo "0")
    py_minor=$(python3 -c "import sys; print(sys.version_info.minor)" 2>/dev/null || echo "0")
    if [ "$py_major" = "3" ] && [ "$py_minor" -ge "$MIN_PYTHON_MINOR" ]; then
        PYTHON_BIN="python3"
        echo "  Using system Python: $(python3 --version 2>&1)"
    fi
fi

# If system python is not sufficient, use or install pyenv
if [ -z "$PYTHON_BIN" ]; then
    echo "  System Python is too old (need >= 3.12). Setting up via pyenv..."

    # Initialize pyenv if already installed
    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PATH"
    if command -v pyenv &>/dev/null; then
        eval "$(pyenv init -)"
    fi

    # Install pyenv if not present
    if ! command -v pyenv &>/dev/null; then
        echo "  Installing pyenv dependencies..."
        if command -v yum &>/dev/null; then
            sudo yum install -y gcc zlib-devel bzip2 bzip2-devel readline-devel \
                sqlite sqlite-devel openssl-devel xz xz-devel libffi-devel
        elif command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y build-essential libssl-dev \
                zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libffi-dev \
                liblzma-dev
        fi

        echo "  Installing pyenv..."
        curl -s https://pyenv.run | bash

        export PYENV_ROOT="$HOME/.pyenv"
        export PATH="$PYENV_ROOT/bin:$PATH"
        eval "$(pyenv init -)"
    fi

    # Install Python 3.12.0 if not already installed
    if ! pyenv versions --bare 2>/dev/null | grep -q "^3\.12\.0$"; then
        echo "  Installing Python 3.12.0 via pyenv (this may take a few minutes)..."
        pyenv install 3.12.0
    fi

    pyenv global 3.12.0
    PYTHON_BIN="$(pyenv which python3 2>/dev/null || pyenv which python)"
    echo "  Using pyenv Python: $("$PYTHON_BIN" --version 2>&1)"
fi

VENV_DIR="$SCRIPT_DIR/.venv"
if [ ! -d "$VENV_DIR" ]; then
    "$PYTHON_BIN" -m venv "$VENV_DIR"
    echo "  Created venv at $VENV_DIR"
fi
"$VENV_DIR/bin/pip" install --quiet websockets pycryptodome
echo "  Python dependencies installed."

"$VENV_DIR/bin/python" "$SCRIPT_DIR/test_flashblock_reorg.py" --ws-url ws://localhost:11113 --rpc-url http://localhost:8124 --verbose &
REORG_TEST_PID=$!
launch_and_verify "test_flashblock_reorg.py" "$REORG_TEST_PID" 5
echo ""

# --- Step 5: Run transfer leader test (background) ---
echo ">>> Step 5: Starting transfer leader test (background)..."
cd "$DEVNET_DIR"
bash "$SCRIPT_DIR/test_transfer_leader.sh" 3 &
TRANSFER_LEADER_PID=$!
launch_and_verify "test_transfer_leader.sh" "$TRANSFER_LEADER_PID" 3
echo ""

# --- Wait for all background processes ---
echo ">>> All tests running. Press Ctrl+C to stop all and exit."
echo ">>> To generate transactions, run adventure ERC20 separately (see script header)."
wait $TRANSFER_LEADER_PID 2>/dev/null || true
wait $REORG_TEST_PID 2>/dev/null || true

echo ""
echo "============================================"
echo "  Flashblocks Reorg Test Complete"
echo "============================================"
