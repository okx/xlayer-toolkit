#!/bin/bash
# kona-connect-peer.sh — Make kona follower(s) dial the sequencer via opp2p_connectPeer
# (kona has no --p2p.static equivalent).
#
# The seq's PeerID is discovered at runtime from `opp2p_self`, so it stays correct
# even when --p2p.priv.raw in docker-compose changes. host/port of the seq's libp2p
# endpoint stay externally configurable since they're docker-network topology, not
# node identity.
#
# Usage:  kona-connect-peer.sh [FLAGS] <follower-rpc-url> [<follower-rpc-url> ...]
# Flags:
#   --seq-rpc URL          Seq's RPC for opp2p_self (default: http://localhost:9545)
#   --peer-host HOST       Hostname followers should dial seq at (default: op-seq)
#   --peer-port PORT       Seq libp2p TCP port (default: 9223)
#   --peer MULTIADDR       Override entirely; skip auto-discovery
#   --health-timeout N     Wait up to N seconds for /healthz (default: 60)
#   --no-wait              Don't wait for /healthz
# Env:    KONA_SEQ_RPC, KONA_PEER_{HOST,PORT,MULTIADDR}, KONA_HEALTH_TIMEOUT

set -euo pipefail

SEQ_RPC="${KONA_SEQ_RPC:-http://localhost:9545}"
PEER_HOST="${KONA_PEER_HOST:-op-seq}"
PEER_PORT="${KONA_PEER_PORT:-9223}"
PEER_MULTIADDR="${KONA_PEER_MULTIADDR:-}"
HEALTH_TIMEOUT="${KONA_HEALTH_TIMEOUT:-60}"
WAIT_HEALTHZ=true
RPC_URLS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --seq-rpc)        SEQ_RPC="$2"; shift 2 ;;
        --peer)           PEER_MULTIADDR="$2"; shift 2 ;;
        --peer-host)      PEER_HOST="$2"; shift 2 ;;
        --peer-port)      PEER_PORT="$2"; shift 2 ;;
        --health-timeout) HEALTH_TIMEOUT="$2"; shift 2 ;;
        --no-wait)        WAIT_HEALTHZ=false; shift ;;
        -h|--help)
            sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^# \?//; /^set -euo pipefail/d'
            exit 0
            ;;
        --) shift; RPC_URLS+=("$@"); break ;;
        -*) echo "❌ unknown flag: $1" >&2; exit 1 ;;
        *)  RPC_URLS+=("$1"); shift ;;
    esac
done

if [ "${#RPC_URLS[@]}" -eq 0 ]; then
    echo "❌ at least one <follower-rpc-url> is required" >&2
    echo "   run with --help for usage" >&2
    exit 1
fi

wait_healthz() {
    local url=$1
    local deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
    until curl -sf "${url}/healthz" > /dev/null 2>&1; do
        if [ "$(date +%s)" -gt "$deadline" ]; then
            echo "❌ ${url} did not become healthy within ${HEALTH_TIMEOUT}s" >&2
            return 1
        fi
        sleep 1
    done
}

# Discover seq's PeerID via opp2p_self unless an explicit multiaddr is pinned.
if [ -z "$PEER_MULTIADDR" ]; then
    if [ "$WAIT_HEALTHZ" = "true" ]; then
        echo "Waiting for seq RPC ${SEQ_RPC}/healthz..."
        wait_healthz "$SEQ_RPC"
    fi

    echo "Discovering seq PeerID from ${SEQ_RPC}..."
    # opp2p_self.addresses[] looks like "/ip4/.../tcp/9223/p2p/<PeerId>";
    # extract just the trailing PeerId — listen IP from opp2p_self may be 0.0.0.0
    # and unreachable for callers, so we combine PeerId with externally-supplied
    # host/port instead.
    PEER_ID=$(curl -s -X POST -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"opp2p_self"}' \
        "$SEQ_RPC" \
        | jq -r '.result.addresses[]? // empty' \
        | sed -n 's|.*/p2p/||p' \
        | head -n1)

    if [ -z "$PEER_ID" ]; then
        echo "❌ failed to read seq PeerID from ${SEQ_RPC} via opp2p_self" >&2
        exit 1
    fi

    PEER_MULTIADDR="/dns4/${PEER_HOST}/tcp/${PEER_PORT}/p2p/${PEER_ID}"
fi

echo "Target peer: $PEER_MULTIADDR"

for rpc_url in "${RPC_URLS[@]}"; do
    if [ "$WAIT_HEALTHZ" = "true" ]; then
        echo "Waiting for ${rpc_url}/healthz (timeout ${HEALTH_TIMEOUT}s)..."
        wait_healthz "$rpc_url" || exit 1
    fi

    echo "Connecting ${rpc_url} → ${PEER_MULTIADDR}"
    response=$(curl -s -X POST -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"opp2p_connectPeer\",\"params\":[\"${PEER_MULTIADDR}\"]}" \
        "$rpc_url")
    echo "  response: $response"
done
