#!/bin/bash

set -e

source /.env

# Enable jemalloc profiling if requested
# Note: tikv-jemalloc (used by Rust) uses _RJEM_MALLOC_CONF, not MALLOC_CONF
if [ "${JEMALLOC_PROFILING:-false}" = "true" ]; then
    export _RJEM_MALLOC_CONF="prof:true,prof_prefix:/profiling/jeprof,lg_prof_interval:30"
    echo "Jemalloc profiling enabled: _RJEM_MALLOC_CONF=$_RJEM_MALLOC_CONF"
fi

if [ "${USE_CHAINSPEC:-false}" = "true" ]; then
    CHAIN="xlayer-devnet"
else
    CHAIN="/genesis.json"
fi

# Build storage flags
RETH_INIT_STORAGE_FLAGS=""
if [ "${RETH_STORAGE_V2:-false}" = "true" ]; then
    if [ -n "${RETH_ROCKSDB_PATH:-}" ]; then
        RETH_INIT_STORAGE_FLAGS="$RETH_INIT_STORAGE_FLAGS --datadir.rocksdb=$RETH_ROCKSDB_PATH"
    fi
else
    # Opt out of storage v2 only if this op-reth build exposes the flag. The
    # xlayer gasless reth build has no --storage.v2 and would abort with
    # "unexpected argument '--storage.v2'".
    if op-reth node --help 2>/dev/null | grep -q -- '--storage.v2'; then
        RETH_INIT_STORAGE_FLAGS="--storage.v2=false"
    fi
fi

CMD="op-reth node \
      --datadir=/datadir \
      --chain=$CHAIN \
      --config=/config.toml \
      $RETH_INIT_STORAGE_FLAGS \
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
      --authrpc.addr=0.0.0.0 \
      --authrpc.port=8552 \
      --authrpc.jwtsecret=/jwt.txt \
      --trusted-peers=$TRUSTED_PEERS \
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
      --metrics=0.0.0.0:9001 \
      --xlayer.sequencer-mode"

# Enable XLayer gasless (zero gas price) transactions in the mempool
if [ "${ENABLE_GASLESS:-false}" = "true" ]; then
    CMD="$CMD --rollup.allow-gasless"
fi

# Gasless tuning flags only exist on newer op-reth builds; apply each only if the
# binary advertises it (older builds abort on an unknown argument). --help is
# evaluated once and reused.
RETH_NODE_HELP="$(op-reth node --help 2>/dev/null || true)"
if echo "$RETH_NODE_HELP" | grep -q -- '--rollup.gasless-mock-gas-price-percentile'; then
    CMD="$CMD --rollup.gasless-mock-gas-price-percentile=${GASLESS_MOCK_GAS_PRICE_PERCENTILE:-0.1}"
fi
if echo "$RETH_NODE_HELP" | grep -q -- '--rollup.gasless-pending-lifetime'; then
    CMD="$CMD --rollup.gasless-pending-lifetime=${GASLESS_PENDING_LIFETIME_SECS:-600}"
fi
if echo "$RETH_NODE_HELP" | grep -q -- '--builder.gasless-block-gas-limit'; then
    CMD="$CMD --builder.gasless-block-gas-limit=${BUILDER_GASLESS_BLOCK_GAS_LIMIT:-60000000}"
fi

# For flashblocks architecture
if [ "$FLASHBLOCK_ENABLED" = "true" ]; then
    CMD="$CMD \
        --flashblocks.enabled \
        --flashblocks.disable-state-root \
        --flashblocks.disable-async-calculate-state-root \
        --flashblocks.addr=0.0.0.0 \
        --flashblocks.port=1111 \
        --flashblocks.block-time=150 \
        --flashblocks.replay-from-persistence-file"

    if [ "$CONDUCTOR_ENABLED" = "true" ]; then
        CMD="$CMD \
            --flashblocks.p2p_port=9009 \
            --flashblocks.p2p_private_key_file=/datadir/fb-p2p-key"

        INDEX="${1:-}"
        if [ -z "$INDEX" ]; then
            # op-reth-seq connects to op-reth-seq2
            CMD="$CMD --flashblocks.p2p_known_peers=/dns4/op-reth-seq2/tcp/9009/p2p/12D3KooWGnxtRXJWhNtwKmRjpqj5QFQPskjWJkC7AkGWhCXBM6ed"
        else
            # op-reth-seq2 connects to op-reth-seq
            CMD="$CMD --flashblocks.p2p_known_peers=/dns4/op-reth-seq/tcp/9009/p2p/12D3KooWC6qFQzcS6V6Tp53nRqw2pmU1snjSYq7H4Q6ckTWAskTt"
        fi
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
