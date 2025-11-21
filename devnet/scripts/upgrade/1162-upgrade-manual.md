# MIPS Upgrade: v7 → v8 (Manual Steps)

## Overview

This guide provides step-by-step manual instructions for upgrading MIPS prestate from v7 to v8.

**Workflow:**
1. **Mac**: Download genesis files from server → Build v8 prestate → Upload to server
2. **Server**: Extract prestate → Compare hashes → Update L1 (if needed) → Restart services

## File Transfer Summary

**Download from Server to Mac (Step 1):**
- `config-op/rollup.json`
- `config-op/genesis.json.gz`
- `l1-geth/execution/genesis.json`

**Upload from Mac to Server (Step 7):**
- `prestate-v8-${TIMESTAMP}.tar.gz`

---

## Part 1: Mac Local Operations

### Step 1: Download Genesis Files from Server

**Files to download from server:**

From server's devnet directory, download these 3 files:
1. `config-op/rollup.json` → Save as `rollup.json`
2. `config-op/genesis.json.gz` → Save as `genesis.json.gz`
3. `l1-geth/execution/genesis.json` → Save as `l1-genesis.json`

**On Mac, prepare directory:**
```bash
cd ~/workspace/xlayer/xlayer-toolkit/devnet
mkdir -p genesis-from-server
```

**Place downloaded files into `genesis-from-server/` directory:**
- `genesis-from-server/rollup.json`
- `genesis-from-server/genesis.json.gz`
- `genesis-from-server/l1-genesis.json`

Verify downloads:
```bash
ls -lh genesis-from-server/
```

Expected output: 3 files listed above

---

### Step 2: Get CHAIN_ID

```bash
CHAIN_ID=$(jq -r '.l2_chain_id' genesis-from-server/rollup.json)
echo "CHAIN_ID: $CHAIN_ID"
```

---

### Step 3: Set Docker Configuration

Check Docker type:
```bash
docker info -f "{{println .SecurityOptions}}" | grep rootless
```

**If output is empty (default Docker):**
```bash
DOCKER_CMD="docker run --rm -v /var/run/docker.sock:/var/run/docker.sock"
DOCKER_TYPE="default"
```

**If output shows "rootless" (rootless Docker):**
```bash
DOCKER_CMD="docker run --rm --privileged"
DOCKER_TYPE="rootless"
```

Set image tag:
```bash
OP_STACK_IMAGE_TAG="op-stack:dev-v0.0.11"
```

---

### Step 4: Build v8 Prestate (5-10 minutes)

Create output directory:
```bash
mkdir -p prestate-v8-output
```

Build prestate:
```bash
$DOCKER_CMD \
    -v "$(pwd)/scripts:/scripts" \
    -v "$(pwd)/genesis-from-server/rollup.json:/app/op-program/chainconfig/configs/${CHAIN_ID}-rollup.json" \
    -v "$(pwd)/genesis-from-server/genesis.json.gz:/app/op-program/chainconfig/configs/${CHAIN_ID}-genesis-l2.json" \
    -v "$(pwd)/genesis-from-server/l1-genesis.json:/app/op-program/chainconfig/configs/1337-genesis-l1.json" \
    -v "$(pwd)/prestate-v8-output:/app/op-program/bin" \
    "${OP_STACK_IMAGE_TAG}" \
    bash -c "/scripts/docker-install-start.sh $DOCKER_TYPE && make -C op-program reproducible-prestate"
```

---

### Step 5: Extract Version and Hash

```bash
NEW_VERSION=$(gunzip -c prestate-v8-output/prestate-mt64.bin.gz | od -An -t u1 -N 1 | xargs)
echo "New Version: v${NEW_VERSION}"
```

Expected output: `New Version: v8`

```bash
NEW_HASH=$(jq -r '.pre' prestate-v8-output/prestate-proof-mt64.json)
echo "New Hash: ${NEW_HASH}"
```

Save to files:
```bash
echo "$NEW_VERSION" > prestate-v8-output/VERSION
echo "$NEW_HASH" > prestate-v8-output/HASH
```

---

### Step 6: Package Prestate

```bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
tar -czf prestate-v8-${TIMESTAMP}.tar.gz prestate-v8-output/
```

Verify package:
```bash
ls -lh prestate-v8-${TIMESTAMP}.tar.gz
```

---

### Step 7: Upload to Server

**File to upload:**

Upload this file to server's devnet directory:
- `prestate-v8-${TIMESTAMP}.tar.gz`

**Target location on server:**
- Place it in the devnet directory (same level as `docker-compose.yml`)

**Note down the timestamp for later:**
```bash
echo $TIMESTAMP
```

Save this timestamp value, you'll need it on the server.

---

## Part 2: Server Operations

**All commands below are executed on the server.**

### Step 1: Navigate to Devnet Directory

```bash
cd /path/to/devnet
```

Replace `/path/to/devnet` with your actual devnet directory path.

Verify you're in the correct directory:
```bash
ls -lh docker-compose.yml .env
```

Expected: Both files should exist

---

### Step 2: Extract Prestate

```bash
tar -xzf prestate-v8-*.tar.gz
```

Verify extraction:
```bash
ls -lh prestate-v8-output/
```

Load new version and hash:
```bash
NEW_VERSION=$(cat prestate-v8-output/VERSION)
NEW_HASH=$(cat prestate-v8-output/HASH)
echo "New: v${NEW_VERSION} - ${NEW_HASH}"
```

---

### Step 3: Load Environment Variables

```bash
source .env
```

Verify critical variables:
```bash
echo "L1_RPC_URL: ${L1_RPC_URL}"
echo "DISPUTE_GAME_FACTORY_ADDRESS: ${DISPUTE_GAME_FACTORY_ADDRESS}"
echo "CHAIN_ID: ${CHAIN_ID}"
```

---

### Step 4: Check Current Version

```bash
OLD_VERSION=$(gunzip -c saved-cannon-data/prestate-mt64.bin.gz | od -An -t u1 -N 1 | xargs)
echo "Old Version: v${OLD_VERSION}"
```

Expected output: `Old Version: v7`

```bash
OLD_HASH=$(jq -r '.pre' saved-cannon-data/prestate-proof-mt64.json)
echo "Old Hash: ${OLD_HASH}"
```

---

### Step 5: Compare Hashes

```bash
echo "Old Hash: ${OLD_HASH}"
echo "New Hash: ${NEW_HASH}"
```

**Manual Decision:**
- If hashes are **identical** → Skip to Step 9 (no L1 update needed)
- If hashes are **different** → Continue to Step 6 (L1 update required)

---

### Step 6: Backup Current Prestate

```bash
BACKUP_DIR="data/cannon-data.backup.$(date +%Y%m%d_%H%M%S)"
cp -r data/cannon-data "$BACKUP_DIR"
echo "Backup created: $BACKUP_DIR"
```

```bash
cp -r saved-cannon-data "saved-cannon-data.backup.$(date +%Y%m%d_%H%M%S)"
```

---

### Step 7: Replace Prestate Files

```bash
rm -rf saved-cannon-data-v8
cp -r prestate-v8-output saved-cannon-data-v8
```

```bash
rm -rf data/cannon-data
cp -r saved-cannon-data-v8 data/cannon-data
```

Verify replacement:
```bash
ls -lh data/cannon-data/
```

---

### Step 8: Update L1 Contracts (Skip if hashes are identical)

**⚠️ Only execute this step if hashes are different!**

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

**💰 This will cost gas (~2-5M gas)**

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

**💰 This will cost gas (~50-100k gas)**

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

---

### Step 9: Update .env Configuration (Skip if hashes are identical)

**⚠️ Only execute this step if L1 was updated (Step 8 executed)**

Check if GAME_TYPE exists:
```bash
grep "^GAME_TYPE=" .env
```

**If line exists:**
```bash
sed -i "s/^GAME_TYPE=.*/GAME_TYPE=0/" .env
```

**If line does not exist:**
```bash
echo "" >> .env
echo "GAME_TYPE=0" >> .env
```

Verify update:
```bash
grep "^GAME_TYPE=" .env
```

Expected output: `GAME_TYPE=0`

---

### Step 10: Restart Services

Stop services:
```bash
docker compose stop op-challenger op-proposer
```

Start services:
```bash
docker compose up -d op-challenger op-proposer
```

Check service status:
```bash
docker compose ps op-challenger op-proposer
```

Expected: Both services show "Up" status

---

### Step 11: Verify Upgrade

Wait for services to stabilize:
```bash
sleep 10
```

Check op-challenger logs:
```bash
docker logs op-challenger --tail 30 | grep -i "pre-state\|version"
```

Look for: "Loaded absolute pre-state"

Check op-proposer logs:
```bash
docker logs op-proposer --tail 30 | grep -i "proposing\|error"
```

Look for: "Proposing" messages

Verify current GAME_TYPE:
```bash
grep "^GAME_TYPE=" .env
```

**If L1 was updated (Step 8 executed):**

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