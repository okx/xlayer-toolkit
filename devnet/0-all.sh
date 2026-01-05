#!/bin/bash
set -e

./1-start-l1.sh
./2-deploy-op-contracts.sh
./3-op-init.sh
./4-op-start-service.sh
./5-run-op-succinct.sh
./6-run-kailua.sh

# RAILGUN Privacy System (Optional, controlled by RAILGUN_ENABLE)
./7-deploy-railgun.sh
./8-deploy-subgraph.sh
./9-test-wallet.sh

echo ""
echo "🎉 Complete DevNet deployment finished!"
echo ""