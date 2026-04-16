#!/bin/bash

set -e

source /.env

# Enable jemalloc profiling if requested
# Note: tikv-jemalloc (used by Rust) uses _RJEM_MALLOC_CONF, not MALLOC_CONF
if [ "${JEMALLOC_PROFILING:-false}" = "true" ]; then
    export _RJEM_MALLOC_CONF="prof:true,prof_prefix:/profiling/jeprof,lg_prof_interval:30"
    echo "Jemalloc profiling enabled: _RJEM_MALLOC_CONF=$_RJEM_MALLOC_CONF"
fi

# Read the first argument (1 or 0), default to 0 if not provided
FLASHBLOCKS_RPC=${FLASHBLOCKS_RPC:-"true"}

if [ "${USE_CHAINSPEC:-false}" = "true" ]; then
    CHAIN="xlayer-devnet"
else
    CHAIN="/genesis.json"
fi

# Build base RocksDB flags
ROCKSDB_FLAGS=""
if [ "${RETH_STORAGE_V2:-false}" = "true" ]; then
    ROCKSDB_FLAGS="--storage.v2"
    if [ -n "${RETH_ROCKSDB_PATH:-}" ]; then
        ROCKSDB_FLAGS="$ROCKSDB_FLAGS --datadir.rocksdb=$RETH_ROCKSDB_PATH"
    fi
fi

# Build the command with common arguments.
# Note that we mock enable legacy RPC by pointing to the sequencer RPC endpoint.
# Since gnesis block is 8593921, we set the override cutoff block height to height
# 8593925, which is aligned on our e2e test coverage constants for forwarding
# RPC calls to the legacy RPC endpoint.
CMD="op-reth node \
      --datadir=/datadir \
      --chain=$CHAIN \
      --config=/config.toml \
      $ROCKSDB_FLAGS \
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
      --authrpc.addr=0.0.0.0 \
      --authrpc.port=8552 \
      --authrpc.jwtsecret=/jwt.txt \
      --trusted-peers=$TRUSTED_PEERS \
      --tx-propagation-policy=trusted \
      --txpool.max-account-slots=100000 \
      --txpool.pending-max-count=100000 \
      --txpool.queued-max-count=100000 \
      --txpool.basefee-max-count=100000 \
      --txpool.max-pending-txns=100000 \
      --txpool.max-new-txns=100000 \
      --rpc.eth-proof-window=10000 \
      --rpc.legacy-url=http://op-reth-seq:8545 \
      --rpc.legacy-cutoff-override=8593925"

# For flashblocks architecture. Enable flashblocks RPC
if [ "$FLASHBLOCK_ENABLED" = "true" ] && [ "$FLASHBLOCKS_RPC" = "true" ]; then
    CMD="$CMD \
        --flashblocks.addr=0.0.0.0 \
        --flashblocks.port=1111 \
        --xlayer.flashblocks-url=ws://op-reth-seq:1111 \
        --xlayer.flashblocks-subscription"

    # Enable flashblocks state comparison debug mode
    if [ "$FLASHBLOCKS_DEBUG_STATE_COMPARISON" = "true" ]; then
        CMD="$CMD --xlayer.flashblocks-debug-state-comparison"
    fi
fi

# Bridge intercept configuration
if [ "${XLAYER_INTERCEPT_ENABLED:-false}" = "true" ]; then
    CMD="$CMD --xlayer.intercept.enabled"
    if [ -n "${XLAYER_INTERCEPT_BRIDGE_CONTRACT:-}" ]; then
        CMD="$CMD --xlayer.intercept.bridge-contract=$XLAYER_INTERCEPT_BRIDGE_CONTRACT"
    fi
    if [ -n "${XLAYER_INTERCEPT_TARGET_TOKEN:-}" ]; then
        CMD="$CMD --xlayer.intercept.target-token=$XLAYER_INTERCEPT_TARGET_TOKEN"
    fi
fi

exec $CMD
