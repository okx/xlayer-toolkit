# MIPS Upgrade: v7 → v8 (Manual Steps)

## Overview

This guide provides step-by-step manual instructions for upgrading MIPS prestate from v7 to v8.

**Workflow:**
1. **Mac**: Download genesis files from server → Build v8 prestate → Upload to server
2. **Server**: Extract prestate → Compare hashes → Update L1 (if needed) → Restart services

## File Transfer Summary
## Part 1: Mac Local Operations
```bash
cd scripts/upgrade
./build-prestate.sh
jq -r '.pre' prestate-proof-mt64.json
```

### Step 7: Upload to Server
Upload `prestate-v8.tar.gz` to server's devnet directory

```bash
jq -r '.pre' prestate-proof-mt64.json
cp -r new-prestate-output/*  cannon-data/
```

### Step 8: Update L1 Contracts
#### 8.1 Get Reference Game Parameters

```bash
REF_GAME=$(cast call --rpc-url "${L1_RPC_URL}" "${DISPUTE_GAME_FACTORY_ADDRESS}" 'gameImpls(uint32)(address)' 1)
echo "Reference game: ${REF_GAME}"
```

```bash
MAX_GAME_DEPTH=$(cast call --rpc-url "${L1_RPC_URL}" "${REF_GAME}" 'maxGameDepth()')
SPLIT_DEPTH=$(cast call --rpc-url "${L1_RPC_URL}" "${REF_GAME}" 'splitDepth()')
CLOCK_EXT=$(cast call --rpc-url "${L1_RPC_URL}" "${REF_GAME}" 'clockExtension()(uint64)')
MAX_CLOCK=$(cast call --rpc-url "${L1_RPC_URL}" "${REF_GAME}" 'maxClockDuration()(uint64)')
VM=$(cast call --rpc-url "${L1_RPC_URL}" "${REF_GAME}" 'vm()(address)')
WETH=$(cast call --rpc-url "${L1_RPC_URL}" "${REF_GAME}" 'weth()(address)')
ASR=$(cast call --rpc-url "${L1_RPC_URL}" "${REF_GAME}" 'anchorStateRegistry()(address)')
L2_CHAIN_ID=$(cast call --rpc-url "${L1_RPC_URL}" "${REF_GAME}" 'l2ChainId()')
```

Verify parameters:
```bash
echo "MAX_GAME_DEPTH: ${MAX_GAME_DEPTH}"
echo "SPLIT_DEPTH: ${SPLIT_DEPTH}"
echo "CLOCK_EXT: ${CLOCK_EXT}"
echo "MAX_CLOCK: ${MAX_CLOCK}"
echo "VM: ${VM}"
echo "WETH: ${WETH}"
echo "ASR: ${ASR}"
echo "L2_CHAIN_ID: ${L2_CHAIN_ID}"
```

#### 8.2 Get FaultDisputeGame Bytecode

```bash
BYTECODE=$(docker run --rm "${OP_STACK_IMAGE_TAG}" bash -c "
    cd /app/packages/contracts-bedrock && \
    forge inspect src/dispute/FaultDisputeGame.sol:FaultDisputeGame bytecode
")
```

Verify bytecode:
```bash
echo "Bytecode length: ${#BYTECODE}"
```

Expected: several thousand characters

#### 8.3 Encode Constructor Arguments

```bash
CONSTRUCTOR_ARGS=$(cast abi-encode \
    "constructor(uint32,bytes32,uint256,uint256,uint64,uint64,address,address,address,uint256)" \
    0 "${NEW_HASH}" "${MAX_GAME_DEPTH}" "${SPLIT_DEPTH}" \
    "${CLOCK_EXT}" "${MAX_CLOCK}" "${VM}" "${WETH}" "${ASR}" "${L2_CHAIN_ID}")
```

Verify encoding:
```bash
echo "Constructor args: ${CONSTRUCTOR_ARGS:0:100}..."
```

#### 8.4 Deploy New FaultDisputeGame Contract

```bash
TX_OUTPUT=$(cast send --rpc-url "${L1_RPC_URL}" --private-key "${DEPLOYER_PRIVATE_KEY}" \
    --legacy --create "${BYTECODE}${CONSTRUCTOR_ARGS:2}" --json)
```

Extract contract address:
```bash
NEW_GAME_ADDRESS=$(echo "$TX_OUTPUT" | jq -r '.contractAddress')
echo "Deployed contract: ${NEW_GAME_ADDRESS}"
```

#### 8.5 Verify Deployed Contract

```bash
DEPLOYED_PRESTATE=$(cast call --rpc-url "${L1_RPC_URL}" "${NEW_GAME_ADDRESS}" 'absolutePrestate()')
echo "Deployed prestate: ${DEPLOYED_PRESTATE}"
echo "Expected:          ${NEW_HASH}"
```

**Manual Check:** The two hashes should match!

#### 8.6 Prepare setImplementation Calldata
```bash
SET_IMPL_CALLDATA=$(cast calldata "setImplementation(uint32,address,bytes)" 0 "${NEW_GAME_ADDRESS}" "0x")
echo "Calldata: ${SET_IMPL_CALLDATA:0:100}..."
```

#### 8.7 Update Game Type 0 Implementation

```bash
TX_OUTPUT=$(cast send --rpc-url "${L1_RPC_URL}" --private-key "${DEPLOYER_PRIVATE_KEY}" \
    --legacy --json "${TRANSACTOR}" "CALL(address,bytes,uint256)" \
    "${DISPUTE_GAME_FACTORY_ADDRESS}" "${SET_IMPL_CALLDATA}" 0)
```

Check transaction status:
```bash
TX_STATUS=$(echo "$TX_OUTPUT" | jq -r '.status')
TX_HASH=$(echo "$TX_OUTPUT" | jq -r '.transactionHash')
echo "Status: ${TX_STATUS}"
echo "TX Hash: ${TX_HASH}"
```

Expected: `Status: 0x1` (success)

#### 8.8 Verify Game Type 0 Update

```bash
GAME0_IMPL=$(cast call --rpc-url "${L1_RPC_URL}" "${DISPUTE_GAME_FACTORY_ADDRESS}" "gameImpls(uint32)(address)" 0)
echo "Game type 0 impl: ${GAME0_IMPL}"
echo "Expected:         ${NEW_GAME_ADDRESS}"
```

**Manual Check:** The two addresses should match (case-insensitive)!
Verify game type 0 on L1:
```bash
GAME0_IMPL=$(cast call --rpc-url "${L1_RPC_URL}" "${DISPUTE_GAME_FACTORY_ADDRESS}" "gameImpls(uint32)(address)" 0)
GAME0_PRESTATE=$(cast call --rpc-url "${L1_RPC_URL}" "${GAME0_IMPL}" 'absolutePrestate()')
echo "Game type 0 prestate: ${GAME0_PRESTATE}"
echo "Expected v8 hash:     ${NEW_HASH}"
```

**Manual Check:** The two hashes should match!

---
## Rollback Procedure

### If You Need to Rollback

Find latest backup:
```bash
BACKUP_DIR=$(ls -dt data/cannon-data.backup.* 2>/dev/null | head -1)
echo "Latest backup: $BACKUP_DIR"
```

Stop services:
```bash
docker compose stop op-challenger op-proposer
```

Restore backup:
```bash
rm -rf data/cannon-data
cp -r "$BACKUP_DIR" data/cannon-data
```

Revert GAME_TYPE (if changed):
```bash
sed -i "s/^GAME_TYPE=.*/GAME_TYPE=1/" .env
```

Restart services:
```bash
docker compose up -d op-challenger op-proposer
```

**⚠️ Important:** L1 contracts cannot be easily rolled back!
- If you updated L1, you need to:
  1. Deploy a new FaultDisputeGame with v7 prestate hash
  2. Call `setImplementation(0, v7_address, "0x")` via Transactor
  3. This will cost additional gas

---

## Troubleshooting

### Mac: File download fails

**Solution:**
- Verify you have access to server's devnet directory
- Check the file paths on server:
  - `config-op/rollup.json`
  - `config-op/genesis.json.gz`
  - `l1-geth/execution/genesis.json`
- Use your available file transfer method (Web UI, FTP, etc.)

### Mac: prestate build fails

Check Docker:
```bash
docker info
```

Check image:
```bash
docker images | grep op-stack
```

Check genesis files:
```bash
ls -lh genesis-from-server/
```

### Server: L1 transaction fails

Check deployer balance:
```bash
source .env
DEPLOYER_ADDRESS=$(cast wallet address --private-key "${DEPLOYER_PRIVATE_KEY}")
cast balance --rpc-url "${L1_RPC_URL}" "${DEPLOYER_ADDRESS}"
```

Check L1 node:
```bash
cast block-number --rpc-url "${L1_RPC_URL}"
```

### Server: Service restart fails

Check service status:
```bash
docker compose ps -a
```

Check logs:
```bash
docker compose logs --tail 100 op-challenger
docker compose logs --tail 100 op-proposer
```

Force recreate:
```bash
docker compose up -d --force-recreate op-challenger op-proposer
```

---

## Quick Reference Commands

### Mac Commands

```bash
# Check version
gunzip -c prestate-v8-output/prestate-mt64.bin.gz | od -An -t u1 -N 1 | xargs

# Check hash
jq -r '.pre' prestate-v8-output/prestate-proof-mt64.json
```

### Server Commands

```bash
# Check old version
gunzip -c saved-cannon-data/prestate-mt64.bin.gz | od -An -t u1 -N 1 | xargs

# Check old hash
jq -r '.pre' saved-cannon-data/prestate-proof-mt64.json

# Check new version
gunzip -c data/cannon-data/prestate-mt64.bin.gz | od -An -t u1 -N 1 | xargs

# Check logs
docker logs op-challenger --tail 50 | grep -i "pre-state"
docker logs op-proposer --tail 50 | grep -i "proposing"

# Check L1 game type 0
source .env
cast call --rpc-url "${L1_RPC_URL}" "${DISPUTE_GAME_FACTORY_ADDRESS}" "gameImpls(uint32)(address)" 0

# Check service status
docker compose ps op-challenger op-proposer
```