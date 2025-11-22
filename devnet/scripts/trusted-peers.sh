#!/bin/bash

# Source environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$(dirname "$SCRIPT_DIR")/.env"
source "$ENV_FILE"

# seq1
TRUSTED_PEERS="enode://ef8135659def07b48b54fe2de7d0368e3eaa0a080ef13dde560169357900954be1a1e890b5973a821f9158e512a2da3ff600368f44e18e725a86931eaae5ef64@op-${SEQ_TYPE}-seq:30303"

if [ "$CONDUCTOR_ENABLED" = "true" ]; then
    # seq2
    TRUSTED_PEERS="${TRUSTED_PEERS},enode://d53a3a3ba6a48dba7605b40e1ec448775c98e8def0c8b99b2cc1cc94ac8844ada28e9208934830979cea650362b77c873c7801f52c8590358e5b2b1717172c27@op-${SEQ_TYPE}-seq2:30303"
    # seq3
    TRUSTED_PEERS="${TRUSTED_PEERS},enode://7d55f88b368875a905f641bb451f39c6e825f665ccb7134a75c0bae7f9db82c7f01e37004151e61f21562b92b896b7bee2066c735a11ff6ac11a2c055b9fce40@op-geth-seq3:30303"
fi

if [ "$FLASHBLOCK_ENABLED" = "true" ]; then
    # op-rbuilder1
    TRUSTED_PEERS="${TRUSTED_PEERS},enode://c3a17ace88f38449893f7800b2a4980f2a10f2ad7f55d99e8b9aff6623df39d131f2d2cdc4ca0c60735f5537b946d58eeffad707bb144cdc76c80864f8c89968@op-rbuilder:30303"
    # op-rbuilder2
    TRUSTED_PEERS="${TRUSTED_PEERS},enode://acebe4a62f2f07b17103ff27fa6b081119641d6911fb53c5a4809323bb816f87e92810e253e44b055ab4ed3b01ebe5eef69a4778bddbf78eb7db7533e6c5e41f@op-rbuilder2:30303"
fi

echo "$TRUSTED_PEERS"
