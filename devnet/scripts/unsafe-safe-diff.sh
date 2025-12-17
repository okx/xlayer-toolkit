#!/bin/bash

# Script to monitor the difference between unsafe and safe block heights
# Usage: ./unsafe-safe-diff.sh <op-node-container-name>

if [ $# -eq 0 ]; then
    echo "Error: op-node container name is required"
    echo "Usage: $0 <op-node-container-name>"
    echo "Example: $0 op-seq"
    exit 1
fi

CONTAINER_NAME="$1"

# Check if container exists and is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Error: Container '${CONTAINER_NAME}' is not running"
    echo "Available running containers:"
    docker ps --format '{{.Names}}'
    exit 1
fi

echo "Monitoring unsafe-safe diff from op-node: ${CONTAINER_NAME}"
echo "Diff should be less than 500 in all history"
echo "Press Ctrl+C to stop"
echo ""

docker logs -f "${CONTAINER_NAME}" | grep -iE "Received forkchoice update" | awk '
BEGIN {
    max_diff = 0
}
{
    match($0, /unsafe=[^:]+:([0-9]+)/, unsafe_arr)
    rest = substr($0, RSTART + RLENGTH)
    match(rest, /safe=[^:]+:([0-9]+)/, safe_arr)
    unsafe_dec = unsafe_arr[1]
    safe_dec = safe_arr[1]
    diff = unsafe_dec - safe_dec
    
    if (diff > max_diff) {
        max_diff = diff
    }
    
    printf "%s unsafe=%s safe=%s diff=%s history-max-diff=%s\n", $1, unsafe_dec, safe_dec, diff, max_diff
}'