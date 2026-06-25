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

# rpc1 — the sequencer runs trusted_nodes_only=true, and reth >=2.2 drops
# untrusted *inbound* connections, so the sequencer must trust the RPC replica
# for it to peer (and sync). Fixed enode id is seeded by 3-op-init.sh into
# data/op-reth-rpc/discovery-secret (secret 357d05ae…, id 61478df8…).
if [ "$LAUNCH_RPC_NODE" = "true" ] && [ "$RPC_TYPE" = "reth" ]; then
    TRUSTED_PEERS="${TRUSTED_PEERS},enode://61478df86822759718c3c849b078023745e0c6d96ea17957ae4779199bcf15c9186a17da75b2d6da6b99be49d999101cb1e82c41d370f133df145670dc8213e3@op-${RPC_TYPE}-rpc:30303"
fi

echo "$TRUSTED_PEERS"
