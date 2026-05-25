#!/usr/bin/env bash

# usage:
# ./bn_diff.sh [seq_rpc] [rpc] [interval]
#
# default:
# seq_rpc = http://127.0.0.1:8123
# rpc     = http://127.0.0.1:8124

SEQ_RPC="${1:-http://127.0.0.1:8123}"
RPC="${2:-http://127.0.0.1:8124}"
INTERVAL="${3:-3}"

while true; do
    bn1=$(cast bn --rpc-url "$SEQ_RPC" 2>/dev/null)
    bn2=$(cast bn --rpc-url "$RPC" 2>/dev/null)

    if [[ -z "$bn1" || -z "$bn2" ]]; then
        echo "[$(date '+%F %T')] failed to fetch block number"
    else
        diff=$((bn1 - bn2))
        echo "[$(date '+%F %T')] seq=$bn1 rpc=$bn2 diff=$diff"
    fi

    sleep "$INTERVAL"
done
