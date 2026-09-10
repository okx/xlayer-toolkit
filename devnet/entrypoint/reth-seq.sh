#!/bin/bash

set -e

ENV_FILE="${ENV_FILE:-/.env}"
[ -f "$ENV_FILE" ] || { echo "Missing Reth environment file: $ENV_FILE" >&2; exit 1; }

# Compose injects a per-sequencer RCS_BASE_URL (http://rcsN:9195) into the
# container environment. Sourcing the shared .env below would otherwise
# override it with a single shared value, pointing every op-reth-seqN at the
# same RCS. Preserve the injected value across the sourcing so each
# op-reth-seqN keeps its own RCS endpoint. When nothing was injected, still
# export whatever RCS_BASE_URL the shared .env provides, because sourcing a
# plain `RCS_BASE_URL=...` assignment does not export it and op-reth reads
# this value from its environment.
_INJECTED_RCS_BASE_URL="${RCS_BASE_URL:-}"
# shellcheck disable=SC1090
source "$ENV_FILE"
if [ -n "$_INJECTED_RCS_BASE_URL" ]; then
    export RCS_BASE_URL="$_INJECTED_RCS_BASE_URL"
elif [ -n "${RCS_BASE_URL:-}" ]; then
    export RCS_BASE_URL
fi

# Each generated node has its own suffix and enode. Load it when the
# entrypoint runs in a cluster, while keeping the single-node invocation
# compatible with the entrypoint argument.
ENTRYPOINT_SUFFIX="${1:-}"
if [ -f /identity.env ]; then
    source /identity.env
    ENTRYPOINT_SUFFIX="${SUFFIX:-$ENTRYPOINT_SUFFIX}"
fi

# All generated Reth enodes are supplied through the shared trusted-peer list.
# Do not ask a node to dial its own entry from that list.
OWN_P2P_HOST="op-${SEQ_TYPE}-seq${ENTRYPOINT_SUFFIX}"
_filtered=""
_OLDIFS="$IFS"; IFS=','
for _peer in ${TRUSTED_PEERS:-}; do
    [ -z "$_peer" ] && continue
    case "$_peer" in *"@${OWN_P2P_HOST}:"*) continue ;; esac
    _filtered="${_filtered:+$_filtered,}$_peer"
done
IFS="$_OLDIFS"
TRUSTED_PEERS="$_filtered"

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

# Probe once and reuse the same capability inventory for storage and optional
# XLayer/gasless flags.
RETH_NODE_HELP="$(op-reth node --help 2>/dev/null || true)"

# Build storage flags compatible with both storage-v1 and storage-v2 Reth.
RETH_STORAGE_FLAGS=""
if [ "${RETH_STORAGE_V2:-false}" = "true" ]; then
    [ -n "${RETH_ROCKSDB_PATH:-}" ] && RETH_STORAGE_FLAGS="--datadir.rocksdb=$RETH_ROCKSDB_PATH"
else
    if grep -q -- '--storage.v2' <<<"$RETH_NODE_HELP"; then
        RETH_STORAGE_FLAGS="--storage.v2=false"
    fi
fi

CMD="op-reth node \
      --datadir=/datadir \
      --chain=$CHAIN \
      --config=/config.toml \
      $RETH_STORAGE_FLAGS \
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

if [ -n "$TRUSTED_PEERS" ]; then
    CMD="$CMD --trusted-peers=$TRUSTED_PEERS"
fi

if [ "${ENABLE_GASLESS:-false}" = "true" ]; then
    CMD="$CMD --rollup.allow-gasless"
fi

if grep -q -- '--rollup.gasless-mock-gas-price-percentile' <<<"$RETH_NODE_HELP"; then
    CMD="$CMD --rollup.gasless-mock-gas-price-percentile=${GASLESS_MOCK_GAS_PRICE_PERCENTILE:-0.1}"
fi
if grep -q -- '--rollup.gasless-pending-lifetime' <<<"$RETH_NODE_HELP"; then
    CMD="$CMD --rollup.gasless-pending-lifetime=${GASLESS_PENDING_LIFETIME_SECS:-600}"
fi
if grep -q -- '--builder.gasless-block-gas-limit' <<<"$RETH_NODE_HELP"; then
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

        # FB_KNOWN_PEERS is the full-mesh peer list (all other cluster nodes)
        # computed by scripts/generate-cluster-compose.sh and injected as an
        # environment variable on this container.
        if [ -n "${FB_KNOWN_PEERS:-}" ]; then
            CMD="$CMD --flashblocks.p2p_known_peers=$FB_KNOWN_PEERS"
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
