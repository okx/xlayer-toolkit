#!/bin/bash

set -e

source /app/.env

echo "L1_RPC_URL: ${L1_RPC_URL}"
echo "L1_BEACON_URL: ${L1_BEACON_URL}"
echo "L2_ENGINEKIND: ${L2_ENGINEKIND}"
echo "OP_NODE_BOOTNODE: ${OP_NODE_BOOTNODE}"
echo "P2P_STATIC: ${P2P_STATIC}"

exec /app/op-node/bin/op-node \
  --log.level=info \
  --l2=http://op-${L2_ENGINEKIND}:8552 \
  --l2.jwt-secret=/jwt.txt \
  --sequencer.enabled=false \
  --verifier.l1-confs=1 \
  --rollup.config=/rollup.json \
  --rpc.addr=0.0.0.0 \
  --rpc.port=9545 \
  --p2p.listen.tcp=${NODE_P2P_PORT} \
  --p2p.listen.udp=${NODE_P2P_PORT} \
  --p2p.peerstore.path=/data/p2p/opnode_peerstore_db \
  --p2p.discovery.path=/data/p2p/opnode_discovery_db \
  --p2p.bootnodes=${OP_NODE_BOOTNODE} \
  --p2p.static=${P2P_STATIC} \
  --rpc.enable-admin=true \
  --l1.trustrpc \
  --l1=${L1_RPC_URL} \
  --l1.beacon=${L1_BEACON_URL} \
  --l1.rpckind=standard \
  --conductor.enabled=false \
  --safedb.path=/data/safedb \
  --l2.enginekind=${L2_ENGINEKIND} \
  2>&1 | tee /var/log/op-node/op-node.log

