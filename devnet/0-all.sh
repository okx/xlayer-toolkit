#!/bin/bash
set -e

./1-start-l1.sh
./2-deploy-op-contracts.sh
./3-op-init.sh
./4-op-start-service.sh
./5-run-op-succinct.sh
