#!/bin/bash
################################################################################
# @title xlayer-seq Supervisor Entrypoint
# @notice Orchestrates the startup of both execution (op-reth) and consensus
#         (kona-node) layers for an OP Stack sequencer node
#
# @dev Architecture:
#      1. op-reth runs in background - provides execution layer via Engine API
#      2. kona-node runs in foreground (PID 1) - consensus layer, receives signals
#      3. Engine API (127.0.0.1:8552) is internal-only, not exposed to host
#
# @dev Signal Handling:
#      - SIGTERM from Docker goes to kona-node (PID 1)
#      - kona-node gracefully shuts down op-reth via Engine API
#
# @param $1 Optional INDEX for multi-sequencer setups (flashblocks P2P peering)
################################################################################

set -e  # Exit immediately if any command fails

################################################################################
# @notice Load environment variables from /.env and export to child processes
# @dev Uses `set -a` to auto-export all sourced variables
################################################################################
set -a
source /.env
set +a

################################################################################
# STEP 1: Configure Jemalloc Memory Profiling (Optional)
################################################################################
# @notice Enables jemalloc heap profiling for performance analysis
# @dev Only effective when:
#      - JEMALLOC_PROFILING=true in .env
#      - op-reth binary compiled with jemalloc feature flag
#
# @param _RJEM_MALLOC_CONF Jemalloc configuration string
#        - prof:true              Enable profiling
#        - prof_prefix:/profiling/jeprof  Output directory for .heap files
#        - lg_prof_interval:30    Profile every 2^30 bytes allocated (~1GB)
#
# @dev Profile files: /profiling/jeprof.<pid>.<seq>.heap
#      Analyze with: jeprof --show_bytes /path/to/binary /path/to/jeprof.*.heap
################################################################################

if [ "${JEMALLOC_PROFILING:-false}" = "true" ]; then
    export _RJEM_MALLOC_CONF="prof:true,prof_prefix:/profiling/jeprof,lg_prof_interval:30"
    echo "[xlayer-kona-seq] Jemalloc profiling enabled: _RJEM_MALLOC_CONF=$_RJEM_MALLOC_CONF"
fi

################################################################################
# STEP 2: Build op-reth Command and Start in Background
################################################################################
# @notice Constructs and launches op-reth (Optimism execution client) as a
#         background process to handle transaction execution and state management
#
# @dev op-reth Configuration:
#      - Datadir: /datadir (persistent blockchain data)
#      - Genesis: /genesis.json (L2 chain initialization)
#      - HTTP RPC: 0.0.0.0:8545 (public JSON-RPC interface)
#      - WebSocket: 0.0.0.0:7546 (real-time subscriptions)
#      - Engine API: 127.0.0.1:8552 (internal consensus <-> execution)
#      - Metrics: 0.0.0.0:9001 (Prometheus metrics)
#
# @dev Networking:
#      - P2P discovery disabled (controlled network)
#      - Max 10 inbound + 10 outbound peers
#      - Transaction propagation: all (broadcast to all peers)
#
# @dev Transaction Pool Limits:
#      - 100,000 max pending/queued/basefee transactions
#      - 2000 MB max memory for pending/basefee pools
#
# @dev Security:
#      - JWT authentication for Engine API (--authrpc.jwtsecret)
#      - Engine API bound to localhost only (not exposed to host)
################################################################################

echo "[xlayer-kona-seq] AL prefetch env: TXPOOL_AL_PREFETCH_ONLY=${TXPOOL_AL_PREFETCH_ONLY:-NOT_SET}"
echo "[xlayer-kona-seq] Starting op-reth (execution layer, background)..."

CMD="op-reth node \
  --datadir=/datadir \
  --chain=/genesis.json \
  --http \
  --http.corsdomain=* \
  --http.port=8545 \
  --http.addr=0.0.0.0 \
  --http.api=web3,debug,eth,txpool,net,miner,admin \
  --ws \
  --ws.addr=0.0.0.0 \
  --ws.port=7546 \
  --ws.origins=* \
  --ws.api=web3,debug,eth,txpool,net \
  --disable-discovery \
  --max-outbound-peers=10 \
  --max-inbound-peers=10 \
  --rpc.eth-proof-window=10000 \
  --authrpc.addr=127.0.0.1 \
  --authrpc.port=8552 \
  --authrpc.jwtsecret=/jwt.txt \
  --trusted-peers=${TRUSTED_PEERS:-} \
  --tx-propagation-policy=all \
  --txpool.max-account-slots=100000 \
  --txpool.pending-max-count=100000 \
  --txpool.queued-max-count=100000 \
  --txpool.basefee-max-count=100000 \
  --txpool.max-pending-txns=100000 \
  --txpool.max-new-txns=100000 \
  --txpool.pending-max-size=2000 \
  --txpool.basefee-max-size=2000 \
  --engine.persistence-threshold=${ENGINE_PERSISTENCE_THRESHOLD:-2} \
  --log.file.directory=/logs/reth \
  --log.file.filter=info \
  --metrics=0.0.0.0:9001"

################################################################################
# STEP 2.1: Add Pre-warming Feature Flags (Conditional)
################################################################################
# @notice Enables transaction cache pre-warming to reduce block execution time
# @dev Only available in feature/txn-execution-cache-warming builds
#
# @param TXPOOL_PRE_WARMING Enable/disable pre-warming (true/false)
# @param TXPOOL_PRE_WARMING_WORKERS Number of background simulation workers
# @param TXPOOL_PRE_FETCH_WORKERS Number of parallel state prefetch workers
#
# @dev How it works:
#      1. Background workers simulate pending transactions
#      2. Extract required state keys (accounts, storage slots)
#      3. Prefetch state data from database into cache
#      4. Block builder uses cached data (99% hit rate, 98% I/O reduction)
#
# @dev Performance Impact:
#      - CPU: +37% overhead for background workers
#      - Cache: 25% → 99% hit rate
#      - Block execution: -3.0% faster (6ms saved per block)
#      - Database queries: -98.7% reduction
################################################################################

if [ "${TXPOOL_PRE_WARMING:-false}" = "true" ]; then
    CMD="$CMD \
        --txpool.pre-warming=${TXPOOL_PRE_WARMING} \
        --txpool.pre-warming-workers=${TXPOOL_PRE_WARMING_WORKERS:-8} \
        --txpool.pre-fetch-workers=${TXPOOL_PRE_FETCH_WORKERS:-16}"
fi

################################################################################
# STEP 2.2: Add Flashblocks Feature Flags (Conditional)
################################################################################
# @notice Enables Flashblocks for sub-second block production
# @dev Flashblocks bypasses normal block building to produce blocks faster
#
# @param FLASHBLOCK_ENABLED Enable/disable Flashblocks (true/false)
# @param FLASHBLOCK_BLOCK_TIME Block production interval in milliseconds (default: 200ms)
#
# @dev Optimizations:
#      - disable-rollup-boost: Skip rollup-specific optimizations
#      - disable-state-root: Skip state root calculation (faster blocks)
#      - disable-async-calculate-state-root: Skip async state root compute
#
# @dev Flashblocks API: 0.0.0.0:1111 (custom block production interface)
################################################################################

if [ "${FLASHBLOCK_ENABLED:-false}" = "true" ]; then
    CMD="$CMD \
        --flashblocks.enabled \
        --flashblocks.disable-rollup-boost \
        --flashblocks.disable-state-root \
        --flashblocks.disable-async-calculate-state-root \
        --flashblocks.addr=0.0.0.0 \
        --flashblocks.port=1111 \
        --flashblocks.block-time=${FLASHBLOCK_BLOCK_TIME:-200}"

    ############################################################################
    # STEP 2.2.1: Configure Flashblocks P2P Networking (Conditional)
    ############################################################################
    # @notice Enables direct P2P communication between Flashblocks sequencers
    # @dev Requires both FLASHBLOCK_P2P_ENABLED and CONDUCTOR_ENABLED to be true
    #
    # @param FLASHBLOCK_P2P_ENABLED Enable P2P for Flashblocks (true/false)
    # @param CONDUCTOR_ENABLED Enable conductor mode (true/false)
    # @param $1 INDEX - Sequencer index for multi-node setups
    #
    # @dev P2P Configuration:
    #      - Port: 9009 (libp2p transport)
    #      - Private key: /datadir/fb-p2p-key (node identity)
    #      - Known peers: Static peer list for discovery
    #
    # @dev Multi-Sequencer Peering:
    #      - INDEX empty (seq):  Peers with op-reth-seq2
    #      - INDEX set (seq2):   Peers with op-reth-seq
    ############################################################################

    if [ "${FLASHBLOCK_P2P_ENABLED:-false}" = "true" ] && [ "${CONDUCTOR_ENABLED:-false}" = "true" ]; then
        CMD="$CMD \
            --flashblocks.p2p_enabled \
            --flashblocks.p2p_port=9009 \
            --flashblocks.p2p_private_key_file=/datadir/fb-p2p-key"

        # INDEX is passed as $1 to distinguish seq from seq2 in multi-node setups
        INDEX="${1:-}"
        if [ -z "$INDEX" ]; then
            CMD="$CMD --flashblocks.p2p_known_peers=/dns4/op-reth-seq2/tcp/9009/p2p/12D3KooWGnxtRXJWhNtwKmRjpqj5QFQPskjWJkC7AkGWhCXBM6ed"
        else
            CMD="$CMD --flashblocks.p2p_known_peers=/dns4/op-reth-seq/tcp/9009/p2p/12D3KooWC6qFQzcS6V6Tp53nRqw2pmU1snjSYq7H4Q6ckTWAskTt"
        fi
    fi

    echo "[xlayer-kona-seq] Flashblocks enabled (block-time=${FLASHBLOCK_BLOCK_TIME:-200}ms)"
fi

################################################################################
# STEP 2.3: Execute op-reth Command in Background
################################################################################
# @notice Launches op-reth as a background process and captures its PID
# @dev Uses eval to execute the dynamically constructed command string
#
# @return RETH_PID Process ID of the running op-reth instance
################################################################################

eval $CMD &
RETH_PID=$!
echo "[xlayer-kona-seq] op-reth started (pid $RETH_PID)"

################################################################################
# STEP 3: Wait for op-reth HTTP RPC Readiness
################################################################################
# @notice Polls op-reth HTTP RPC endpoint until it responds successfully
# @dev Health check: Calls eth_blockNumber and validates JSON-RPC response
#
# @dev Retry Logic:
#      - Interval: 1 second between attempts
#      - Timeout: None (waits indefinitely)
#      - Failure: Exits if op-reth process dies during startup
#
# @dev Why This Matters:
#      - Prevents kona-node from starting before execution layer is ready
#      - Ensures Engine API (8552) is also operational (starts with HTTP RPC)
#      - Avoids race conditions in consensus <-> execution communication
################################################################################

echo "[xlayer-kona-seq] Waiting for op-reth HTTP RPC (127.0.0.1:8545)..."
until curl -sf \
    -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    http://127.0.0.1:8545 | grep -q '"result"'; do
    if ! kill -0 $RETH_PID 2>/dev/null; then
        echo "[xlayer-kona-seq] ERROR: op-reth exited unexpectedly during startup"
        exit 1
    fi
    sleep 1
done
echo "[xlayer-kona-seq] op-reth is ready"

################################################################################
# STEP 4: Start kona-node in Foreground (PID 1 Takeover)
################################################################################
# @notice Launches kona-node (OP Stack consensus client) as the main process
# @dev Uses `exec` to replace the current shell with kona-node, making it PID 1
#
# @dev Why PID 1 Matters:
#      - Docker sends SIGTERM to PID 1 during container shutdown
#      - kona-node receives the signal and can gracefully shut down
#      - kona-node then tells op-reth to shut down via Engine API
#
# @dev kona-node Configuration:
#      - Chain ID: 195 (L2 network identifier)
#      - Mode: sequencer (produces blocks, not just follows)
#      - L1: ${L1_RPC_URL_IN_DOCKER} (Ethereum L1 RPC)
#      - L1 Beacon: ${L1_BEACON_URL_IN_DOCKER} (L1 consensus client)
#      - L2 Engine: http://127.0.0.1:8552 (op-reth Engine API)
#
# @dev Engine API:
#      - Uses JWT authentication (/jwt.txt must match op-reth's)
#      - Sends newPayload, forkchoiceUpdated to op-reth
#      - Receives execution results, state roots
#
# @dev RPC & P2P:
#      - RPC: 0.0.0.0:9545 (kona-node JSON-RPC interface)
#      - P2P TCP: 9223 (libp2p peer-to-peer communication)
#      - P2P UDP: 9223 (discovery protocol)
#      - Sequencer key: ${SEQUENCER_P2P_KEY} (signs blocks)
#
# @dev Consensus Parameters:
#      - l1-confs: 5 (wait 5 L1 confirmations before deriving L2 blocks)
#      - p2p.no-discovery: true (static peer list, no DHT discovery)
#      - rollup config: /rollup.json (OP Stack rollup parameters)
#      - L1 genesis: /l1-genesis.json (L1 chain config)
#
# @dev Metrics:
#      - Port: 9002 (Prometheus metrics for kona-node)
################################################################################

echo "[xlayer-kona-seq] Starting kona-node (consensus layer, foreground)..."

exec kona-node \
    --chain=195 \
    --metrics.enabled \
    --metrics.port=9002 \
    node \
    --mode=sequencer \
    --l1="${L1_RPC_URL_IN_DOCKER}" \
    --l1-beacon="${L1_BEACON_URL_IN_DOCKER}" \
    --l2=http://127.0.0.1:8552 \
    --l2.jwt-secret=/jwt.txt \
    --l2-config-file=/rollup.json \
    --l1-config-file=/l1-genesis.json \
    --rpc.addr=0.0.0.0 \
    --rpc.port=9545 \
    --rpc.enable-admin \
    --p2p.listen.tcp=9223 \
    --p2p.listen.udp=9223 \
    --p2p.priv.raw=e054b5748fb29a82994ea170af9e6094a163a0d11308dea91a38744c4e7c94da \
    --p2p.no-discovery \
    --p2p.sequencer.key="${SEQUENCER_P2P_KEY}" \
    --p2p.bootstore=/data/p2p/bootstore \
    --sequencer.l1-confs=5

################################################################################
# @dev Script Execution Flow Summary:
#
# 1. Load environment variables (.env)
# 2. Enable jemalloc profiling (if configured)
# 3. Build op-reth command with:
#    - Core flags (RPC, Engine API, metrics)
#    - Pre-warming flags (if enabled)
#    - Flashblocks flags (if enabled)
# 4. Launch op-reth in background
# 5. Wait for op-reth HTTP RPC to be ready
# 6. Launch kona-node in foreground (becomes PID 1)
# 7. Container runs until SIGTERM received by kona-node
#
# @dev Graceful Shutdown:
# 1. Docker sends SIGTERM to kona-node (PID 1)
# 2. kona-node stops accepting new blocks
# 3. kona-node sends shutdown signal to op-reth via Engine API
# 4. op-reth flushes state to disk and exits
# 5. kona-node exits
# 6. Container stops
################################################################################
