# X Layer EVM Differences & Architecture Migration

## Architecture Migration: Polygon CDK → OP Stack (CRITICAL)

X Layer migrated from **Polygon CDK (zkEVM)** to **OP Stack (optimistic rollup)** on October 27, 2025. This fundamentally changed the chain's operating principles.

| | Pre-Re-genesis (CDK) | Post-Re-genesis (OP Stack) |
|---|---|---|
| **Architecture** | Polygon CDK / zkEVM | Optimism OP Stack |
| **Execution client** | cdk-Erigon | Geth / **Reth** (xlayer-reth) |
| **Proof system** | ZK validity proof | Optimistic + dispute games |
| **EVM compatibility** | zkEVM (limited precompile/opcode) | Standard EVM (full compatibility) |
| **Block time** | Variable | ~1 second (fixed) |
| **Finality** | Minutes (ZK proof) | ~7 days (challenge period, PermissionedDisputeGame) |

**Important:** Post-re-genesis X Layer is fully standard EVM compatible. zkEVM limitations (precompile limits, CREATE2 differences, circuit risks) NO LONGER APPLY — they are only relevant for historical blocks.

## Re-genesis (CRITICAL)

Re-genesis occurred at block **42,810,021** (mainnet, October 27, 2025) = **CDK → OP Stack transition point**.
Testnet re-genesis at block **12,241,700**.

### Routing Rules
| Block Range | Node Type | Architecture | Note |
|---|---|---|---|
| ≤ 42,810,020 | cdk-Erigon | Polygon CDK | `x-qn-height` header may be required (QuickNode) |
| 42,810,021 | — | — | **Untraceable**: `{"code":4444,"message":"pruned history unavailable"}` |
| ≥ 42,810,022 | Geth / Reth | OP Stack | Standard RPC, flashblocks support |

### Historical Data Queries
Applications requiring archive data MUST implement conditional routing:
```typescript
const RE_GENESIS_BLOCK = 42_810_021;

async function getBlock(blockNumber: number, provider: ethers.JsonRpcProvider) {
    if (blockNumber === RE_GENESIS_BLOCK) {
        throw new Error("Block 42810021 is untraceable (re-genesis boundary)");
    }
    if (blockNumber < RE_GENESIS_BLOCK) {
        // Use cdk-Erigon endpoint (old CDK architecture)
        const erigonProvider = new ethers.JsonRpcProvider(ERIGON_RPC_URL);
        return erigonProvider.getBlock(blockNumber);
    }
    // Standard Geth/Reth endpoint (OP Stack)
    return provider.getBlock(blockNumber);
}
```

**Note:** xlayer-reth node supports this routing **built-in**:
- `--rpc.legacy-url` flag to define legacy cdk-Erigon endpoint
- `--rpc.legacy-timeout` for timeout settings (default: 30s)
- Node automatically routes based on block height

### Impact
- Block explorer data before 42,810,021 requires a different endpoint
- Event log queries with fromBlock < 42,810,021 need two separate queries
- Account for this boundary in large range `eth_getLogs` queries
- Subgraphs/indexers must handle this boundary

---

## [LEGACY] Pre-Re-genesis zkEVM Limitations

> **IMPORTANT:** The following limitations apply ONLY to blocks ≤42,810,020 (old Polygon CDK/zkEVM era). Post-re-genesis X Layer runs on **standard EVM compatible** OP Stack — all precompiles and opcodes exhibit standard Ethereum behavior.

### [LEGACY] Limited Precompiles (pre-re-genesis only)

| Precompile | Address | CDK Era | OP Stack (Current) |
|---|---|---|---|
| ecRecover | 0x01 | ✅ | ✅ |
| SHA-256 | 0x02 | ✅ | ✅ |
| RIPEMD-160 | 0x03 | ⚠️ Limited | ✅ Full support |
| identity | 0x04 | ✅ | ✅ |
| modexp | 0x05 | ⚠️ Capacity limit | ✅ Full support |
| ecAdd | 0x06 | ✅ | ✅ |
| ecMul | 0x07 | ✅ | ✅ |
| ecPairing | 0x08 | ✅ | ✅ |
| blake2f | 0x09 | ⚠️ Limited | ✅ Full support |
| point evaluation | 0x0a | ⚠️ Limited | ✅ Full support |

### [LEGACY] CREATE2 Differences (pre-re-genesis only)
- In old zkEVM, `CREATE2` operated through ContractDeployer system contract
- Assembly-level `create2` could produce broken bytecode
- **Post-re-genesis:** Standard Ethereum CREATE2 behavior — full support including assembly

---

## Current (OP Stack) Gas Differences

| Component | Description |
|---|---|
| L2 execution fee | Standard EVM gas cost (same opcode pricing as Ethereum) |
| L1 data fee | Cost of posting calldata to L1 (variable, depends on L1 gas price) |

- Always use `eth_estimateGas` for gas estimation (never hardcode)
- L1 data fee directly tied to tx calldata size — calldata compression optimization matters
- Detailed gas information → `gas-optimization.md`

---

## EVM Opcode Behavior Differences (OP Stack — Current)

### COINBASE
- Ethereum: Block miner/validator address
- X Layer (OP Stack): Sequencer fee vault address (`0x4200000000000000000000000000000000000011`)
- Do NOT use `block.coinbase` for mining reward calculations

### DIFFICULTY / PREVRANDAO
- Ethereum (post-merge): RANDAO value (pseudo-random)
- X Layer: May return a fixed value or 0
- Chainlink VRF is NOT available on X Layer — use commit-reveal for on-chain randomness (see `security.md` → Randomness)

### Block Finality
- Ethereum: ~15 minutes (64 slots)
- X Layer (OP Stack): **~7 day challenge period** (PermissionedDisputeGame active)
- "Soft finality" (sequencer confirmation): ~1 second
- Flashblocks pre-confirmation: ~200ms
- `block.number` and `block.timestamp` are determined by the sequencer
- **Note:** Timing may change when dispute mechanism becomes permissionless

### SELFDESTRUCT
- Post EIP-6780: Only destroys contracts created in the same transaction
- Avoid usage — deprecated

### Jovian Hardfork (X Layer Custom)
- Mainnet activation: 2025-12-02 16:00:01 UTC
- Testnet activation: 2025-11-28 11:00:00 UTC
- X Layer-specific protocol improvements (flashblocks, sequencer optimizations)

---

## X Layer-Specific RPC Methods

### eth_flashblocksEnabled (NEW — OP Stack)
Check if flashblocks are active:
```bash
curl -X POST https://rpc.xlayer.tech \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_flashblocksEnabled","params":[],"id":1}'
```
- Returns: `true` or `false`
- Check before using flashblocks on nodes that may not support them

### [LEGACY] zkevm_* RPC Methods (Pre-Re-genesis)

> These methods only work for querying old CDK era blocks (<42,810,021) — they function on requests routed to legacy cdk-Erigon endpoints.

#### zkevm_batchNumber
Returns the current batch number:
```bash
curl -X POST <CDK_ERIGON_ENDPOINT> \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"zkevm_batchNumber","params":[],"id":1}'
```

#### zkevm_batchNumberByBlockNumber
Finds batch number from block number.

#### zkevm_getBatchByNumber
Returns batch details (tx list, global exit root, timestamp).

### Use Cases
- **Legacy analytics:** Pre-re-genesis era batch data
- **Historical indexer:** CDK era data indexing
- **Note:** Post-re-genesis blocks use OP Stack sequencer batches — different structure
