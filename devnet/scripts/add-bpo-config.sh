#!/bin/sh
set -e

echo "Reading osakaTime and adding bpo1Time, bpo2Time right after it..."
OSAKA_TIME=$(jq -r '.config.osakaTime' /execution/genesis.json)
echo "osakaTime = $OSAKA_TIME"

# Use sed to insert bpo1Time and bpo2Time right after osakaTime line
sed -i "/\"osakaTime\": $OSAKA_TIME,/a\\    \"bpo1Time\": $OSAKA_TIME,\\n    \"bpo2Time\": $OSAKA_TIME," /execution/genesis.json

echo "Ensuring blobSchedule contains bpo1 and bpo2..."
jq '.config.blobSchedule.bpo1 = {"target": 10, "max": 15, "baseFeeUpdateFraction": 5007716} | .config.blobSchedule.bpo2 = {"target": 14, "max": 21, "baseFeeUpdateFraction": 5007716}' /execution/genesis.json > /tmp/genesis.json && mv /tmp/genesis.json /execution/genesis.json

echo "Removing terminalTotalDifficultyPassed for op-node compatibility..."
jq 'del(.config.terminalTotalDifficultyPassed)' /execution/genesis.json > /tmp/genesis.json && mv /tmp/genesis.json /execution/genesis.json

echo "Genesis.json: All fork times synchronized"
cat /execution/genesis.json | jq '.config | {shanghaiTime, cancunTime, pragueTime, osakaTime, bpo1Time, bpo2Time, blobSchedule}'
