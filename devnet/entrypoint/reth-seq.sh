#!/bin/bash

set -e

source /.env

# Enable jemalloc profiling if requested
# Note: tikv-jemalloc (used by Rust) uses _RJEM_MALLOC_CONF, not MALLOC_CONF
if [ "${JEMALLOC_PROFILING:-false}" = "true" ]; then
    export _RJEM_MALLOC_CONF="prof:true,prof_prefix:/profiling/jeprof,lg_prof_interval:30"
    echo "Jemalloc profiling enabled: _RJEM_MALLOC_CONF=$_RJEM_MALLOC_CONF"
fi

CMD="op-reth node \
      --datadir=/datadir \
      --chain=/genesis.json \
      --config=/config.toml \
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
      --metrics=0.0.0.0:9001"

# Enable RocksDB if requested
if [ "${RETH_SEQ_ROCKSDB_ENABLED:-false}" = "true" ]; then
    CMD="$CMD --datadir.rocksdb=/datadir/rocksdb"
    echo "RocksDB enabled via --datadir.rocksdb=/datadir/rocksdb flag"
fi

# For flashblocks architecture
if [ "$FLASHBLOCK_ENABLED" = "true" ]; then
    CMD="$CMD \
        --flashblocks.enabled \
        --flashblocks.disable-rollup-boost \
        --flashblocks.disable-state-root \
        --flashblocks.disable-async-calculate-state-root \
        --flashblocks.addr=0.0.0.0 \
        --flashblocks.port=1111 \
        --flashblocks.block-time=200"

    if [ "$FLASHBLOCK_P2P_ENABLED" = "true" ] && [ "$CONDUCTOR_ENABLED" = "true" ]; then
        CMD="$CMD \
            --flashblocks.p2p_enabled \
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

exec $CMD
