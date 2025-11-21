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

### Step 2: Upload to Server
Upload `prestate-v8.tar.gz` to server's devnet directory

```bash
jq -r '.pre' prestate-proof-mt64.json
cp -r new-prestate-output/*  cannon-data/
```

### Step 8: Update L1 Contracts
#### Summary

**Goal**: Upgrade game type 1 (PermissionedDisputeGame) on L1 from v7 prestate to v8 prestate

**Workflow Overview**:
```
Phase 1: Prepare Parameters (8.1-8.3)
  └─ Read config from old contract → Extract bytecode → Encode constructor (params + v8 hash)

Phase 2: Deploy New Contract (8.4-8.5)
  └─ 💰 Deploy new PermissionedDisputeGame to L1 → Verify prestate = v8 hash

Phase 3: Update Factory Contract (8.6-8.7)
  └─ 💰 Update game type 1 via Transactor → Verify success
```

**On-chain Transactions** (require gas):
- **8.4**: Deploy new contract (~2-5M gas)
- **8.6**: Update DisputeGameFactory.gameImpls[1] (~50-100K gas)

**Other Steps**: Local operations or on-chain reads, no gas required

---

#### 8.1 Get Reference Game Parameters

```bash
REF_GAME=$(cast call --rpc-url "${L1_RPC_URL}" "${DISPUTE_GAME_FACTORY_ADDRESS}" 'gameImpls(uint32)(address)' 1)
echo "Reference game: ${REF_GAME}"

MAX_GAME_DEPTH=$(cast call --rpc-url "${L1_RPC_URL}" "${REF_GAME}" 'maxGameDepth()')
SPLIT_DEPTH=$(cast call --rpc-url "${L1_RPC_URL}" "${REF_GAME}" 'splitDepth()')
CLOCK_EXT=$(cast call --rpc-url "${L1_RPC_URL}" "${REF_GAME}" 'clockExtension()(uint64)')
MAX_CLOCK=$(cast call --rpc-url "${L1_RPC_URL}" "${REF_GAME}" 'maxClockDuration()(uint64)')
VM=$(cast call --rpc-url "${L1_RPC_URL}" "${REF_GAME}" 'vm()(address)')
WETH=$(cast call --rpc-url "${L1_RPC_URL}" "${REF_GAME}" 'weth()(address)')
ASR=$(cast call --rpc-url "${L1_RPC_URL}" "${REF_GAME}" 'anchorStateRegistry()(address)')
L2_CHAIN_ID=$(cast call --rpc-url "${L1_RPC_URL}" "${REF_GAME}" 'l2ChainId()')

echo "MAX_GAME_DEPTH: ${MAX_GAME_DEPTH}"
echo "SPLIT_DEPTH: ${SPLIT_DEPTH}"
echo "CLOCK_EXT: ${CLOCK_EXT}"
echo "MAX_CLOCK: ${MAX_CLOCK}"
echo "VM: ${VM}"
echo "WETH: ${WETH}"
echo "ASR: ${ASR}"
echo "L2_CHAIN_ID: ${L2_CHAIN_ID}"
```

#### 8.2 Get PermissionedDisputeGame Bytecode

```bash
BYTECODE=$(docker run --rm "${OP_STACK_IMAGE_TAG}" bash -c "
    cd /app/packages/contracts-bedrock && \
    forge inspect src/dispute/PermissionedDisputeGame.sol:PermissionedDisputeGame bytecode
")
echo "Bytecode length: ${#BYTECODE} (expected: several thousand)"
```

#### 8.3 Encode Constructor Arguments

```bash
CONSTRUCTOR_ARGS=$(cast abi-encode \
    "constructor(uint32,bytes32,uint256,uint256,uint64,uint64,address,address,address,uint256)" \
    1 "${NEW_HASH}" "${MAX_GAME_DEPTH}" "${SPLIT_DEPTH}" \
    "${CLOCK_EXT}" "${MAX_CLOCK}" "${VM}" "${WETH}" "${ASR}" "${L2_CHAIN_ID}")
echo "Constructor args: ${CONSTRUCTOR_ARGS:0:100}..."
```

#### 8.4 Deploy New PermissionedDisputeGame Contract

```bash
TX_OUTPUT=$(cast send --rpc-url "${L1_RPC_URL}" --private-key "${DEPLOYER_PRIVATE_KEY}" \
    --legacy --create "${BYTECODE}${CONSTRUCTOR_ARGS:2}" --json)
NEW_GAME_ADDRESS=$(echo "$TX_OUTPUT" | jq -r '.contractAddress')
echo "Deployed contract: ${NEW_GAME_ADDRESS}"
```

#### 8.5 Verify Deployed Contract

```bash
DEPLOYED_PRESTATE=$(cast call --rpc-url "${L1_RPC_URL}" "${NEW_GAME_ADDRESS}" 'absolutePrestate()')
echo -e "Deployed prestate: ${DEPLOYED_PRESTATE}\nExpected:          ${NEW_HASH}"
```

**Manual Check:** The two hashes should match!

#### 8.6 Update Game Type 1 Implementation (Permissioned)

```bash
SET_IMPL_CALLDATA=$(cast calldata "setImplementation(uint32,address,bytes)" 1 "${NEW_GAME_ADDRESS}" "0x")
TX_OUTPUT=$(cast send --rpc-url "${L1_RPC_URL}" --private-key "${DEPLOYER_PRIVATE_KEY}" \
    --legacy --json "${TRANSACTOR}" "CALL(address,bytes,uint256)" \
    "${DISPUTE_GAME_FACTORY_ADDRESS}" "${SET_IMPL_CALLDATA}" 0)
echo "TX Status: $(echo "$TX_OUTPUT" | jq -r '.status') (expected: 0x1)"
```

#### 8.7 Verify Game Type 1 Update

```bash
GAME1_IMPL=$(cast call --rpc-url "${L1_RPC_URL}" "${DISPUTE_GAME_FACTORY_ADDRESS}" "gameImpls(uint32)(address)" 1)
echo -e "Game type 1 impl: ${GAME1_IMPL}\nExpected:         ${NEW_GAME_ADDRESS}"

GAME1_PRESTATE=$(cast call --rpc-url "${L1_RPC_URL}" "${GAME1_IMPL}" 'absolutePrestate()')
echo -e "Game type 1 prestate: ${GAME1_PRESTATE}\nExpected v8 hash:     ${NEW_HASH}"
```

**Manual Check:** Both addresses and prestate hash should match!