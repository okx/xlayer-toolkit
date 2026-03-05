#!/bin/bash

WORKERS="8 16 32 64"

wait_for_el_to_start() {
    CONTAINER_NAME=$1
    if [ -z "$CONTAINER_NAME" ]; then
        echo "Error: CONTAINER_NAME is not set"
        exit 1
    fi

    # Wait for execution layer to start
    echo "⏳ Waiting for execution layer to start in ${CONTAINER_NAME} ..."
    MAX_WAIT=300  # 5 minutes timeout
    ELAPSED=0
    FOUND=false

    while [ $ELAPSED -lt $MAX_WAIT ]; do
        if docker logs ${CONTAINER_NAME} 2>&1 | grep -q "Starting consensus engine"; then
            echo "✅ Execution layer started!"
            FOUND=true
            break
        fi
        sleep 2
        ELAPSED=$((ELAPSED + 2))
        if [ $((ELAPSED % 10)) -eq 0 ]; then
            echo "   Still waiting... (${ELAPSED}s/${MAX_WAIT}s)"
        fi
    done

    if [ "$FOUND" = false ]; then
        echo "❌ Error: Timeout waiting for execution layer to start (${MAX_WAIT}s)"
        exit 1
    fi
}

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

LOGS="pre-warm-logs-$(date +%Y%m%d_%H%M%S)"
mkdir -p $LOGS

# run without pre-warming first
echo "Running pre-warm benchmark with pre-warming=false..."
echo "🔄 Stopping op-seq and op-reth-seq..."
docker compose down op-seq op-reth-seq
sed_inplace "s/txpool.pre-warming=[a-z]*/txpool.pre-warming=false/" entrypoint/reth-seq.sh
echo "🚀 Starting op-reth-seq and op-seq..."
docker compose up -d op-reth-seq
wait_for_el_to_start "op-reth-seq"
docker compose up -d op-seq
sleep 30
./devnet_comparison.sh localhost 9001 3 ${LOGS}/prewarming_metrics_no_prewarming.json &
timeout 3m adventure native-bench -f ../tools/adventure/testdata/config.json --csv-report ${LOGS}/tps_no_prewarming.csv
wait
docker logs op-reth-seq | grep "Block added" > ${LOGS}/op-reth-seq-log_no_prewarming.txt 2>&1
sed_inplace "s/txpool.pre-warming=[a-z]*/txpool.pre-warming=true/" entrypoint/reth-seq.sh

for W in $WORKERS; do
    echo "Running pre-warm benchmark with $W workers..."

    echo "🔄 Stopping op-seq and op-reth-seq..."
    docker compose down op-seq op-reth-seq

    sed_inplace "s/txpool.pre-warming-workers=[0-9]*/txpool.pre-warming-workers=$W/" entrypoint/reth-seq.sh

    echo "🚀 Starting op-reth-seq and op-seq..."
    docker compose up -d op-reth-seq
    wait_for_el_to_start "op-reth-seq"
    docker compose up -d op-seq
    sleep 30

    echo "🚀 Running benchmark with $W workers..."
    ./devnet_comparison.sh localhost 9001 3 ${LOGS}/prewarming_metrics_${W}_workers.json &
    timeout 3m adventure native-bench -f ../tools/adventure/testdata/config.json --csv-report ${LOGS}/tps_${W}_workers.csv
    wait
    docker logs op-reth-seq | grep "Block added" > ${LOGS}/op-reth-seq-log_${W}_workers.txt 2>&1
done