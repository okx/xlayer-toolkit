# XLayer Legacy RPC Implementation

Based on [op-geth migration RPC implementation](https://github.com/okx/op-geth/pull/16)

## Parameters

| Parameter | Description |
|-----------|-------------|
| `--rpc.legacy-url` | URL of the legacy Erigon RPC endpoint |
| `--rpc.legacy-timeout` | Timeout for legacy RPC requests in seconds |

## API Implementation Status

| # | RPC Method | Status | Note |
|---|------------|--------|------|
| 1 | `eth_getBlockByNumber` | ✅ | Supports BlockNumber, BlockTag |
| 2 | `eth_getBlockByHash` | ✅ | Supports BlockHash |
| 3 | `eth_getHeaderByNumber` | ❌ | Legacy RPC not supported |
| 4 | `eth_getHeaderByHash` | ❌ | Legacy RPC not supported |
| 5 | `eth_getBlockReceipts` | ✅ | Supports BlockNumber, BlockHash, BlockTag |
| 6 | `eth_getBlockTransactionCountByNumber` | ✅ | Supports BlockNumber, BlockTag |
| 7 | `eth_getBlockTransactionCountByHash` | ✅ | Supports BlockHash |
| 8 | `eth_getTransactionByHash` | ✅ | Hash-based query |
| 9 | `eth_getTransactionReceipt` | ✅ | Hash-based query |
| 10 | `eth_getTransactionByBlockHashAndIndex` | ✅ | Supports BlockHash + index |
| 11 | `eth_getTransactionByBlockNumberAndIndex` | ✅ | Supports BlockNumber, BlockTag + index |
| 12 | `eth_getRawTransactionByHash` | ✅ | Hash-based query |
| 13 | `eth_getRawTransactionByBlockHashAndIndex` | ✅ | Supports BlockHash + index |
| 14 | `eth_getRawTransactionByBlockNumberAndIndex` | ✅ | Supports BlockNumber + index |
| 15 | `eth_getBalance` | ✅ | Supports BlockNumber, BlockHash, BlockTag |
| 16 | `eth_getCode` | ✅ | Supports BlockNumber, BlockHash, BlockTag |
| 17 | `eth_getStorageAt` | ✅ | Supports BlockNumber, BlockHash, BlockTag |
| 18 | `eth_getTransactionCount` | ✅ | Supports BlockNumber, BlockHash, BlockTag |
| 19 | `eth_getLogs` | ✅ | Supports range queries, topics filter |
| 20 | `eth_call` | ✅ | Supports BlockNumber, BlockHash, BlockTag |
| 21 | `eth_estimateGas` | ✅ | Supports BlockNumber, BlockHash, BlockTag |
| 22 | `eth_createAccessList` | ✅ | EIP-2930 access list creation |
| 26 | `eth_newFilter` | ❌ | Real-time query only |
| 27 | `eth_getFilterLogs` | ❌ | Real-time query only |
| 28 | `eth_getFilterChanges` | ❌ | Real-time query only |
| 29 | `eth_uninstallFilter` | ❌ | Real-time query only |

## Integration Testing

Run comprehensive tests:

```bash
cd scripts/dev-utils
./compare-legacy-rpc.sh [rpc_url]
```

See [compare-legacy-rpc.sh](./compare-legacy-rpc.sh) for the complete test suite.

## Test Rules

When adding tests for new RPC methods, ensure coverage across these dimensions:

### 1. Data Existence Tests
- **Valid Data** - Query existing blocks/transactions/accounts
- **Invalid Data** - Query non-existent data (future blocks, random hashes, etc.)
- Expected: Valid data returns results, invalid data returns `null` or error

### 2. Block Location Tests
- **Legacy Block** - Block number < cutoff (should fallback to Legacy RPC)
- **Cutoff Block** - Block number = cutoff (migration point)
- **Local Block** - Block number > cutoff (should query Reth local DB)
- **Boundary Blocks** - Test cutoff-1, cutoff, cutoff+1
- Expected: Correct routing based on block location

### 3. Parameter Type Tests

For methods supporting `BlockId`:
- **BlockNumber** - Hex-encoded block number (e.g., `"0x28d3aa5"`)
- **BlockHash** - 32-byte block hash (e.g., `"0xabc123..."`)
- Expected: Both parameters should work identically for same block

For methods supporting `BlockTag`:
- **"earliest"** - Genesis block (0x0)
- **"latest"** - Most recent block
- **"pending"** - Pending block (may not be supported)
- Expected: Tags resolved to correct block numbers

### 4. Data Consistency Tests

For legacy blocks, verify:
- **Reth vs Legacy RPC** - Compare response from Reth with Legacy RPC
- Expected: Results must be **byte-identical** (no transformation)

### 5. Edge Case Tests
- **Genesis Block** - Query block 0x0
- **Block 1** - Query block 0x1
- **Empty Blocks** - Blocks with zero transactions
- **Future Blocks** - Block numbers beyond chain tip
- **Invalid Hashes** - All-zero hash, random non-existent hash
- **Negative Numbers** - Test error handling for `-0x1`
- **Range Tests** (for `eth_getLogs`):
  - Small range (< 100 blocks)
  - Cross-boundary range (legacy to local)
  - Inverted range (toBlock < fromBlock)

### 6. Helper Function Selection

Choose appropriate check function based on scenario:

| Function | Use Case | Failed/Skipped |
|----------|----------|----------------|
| `check_result` | Standard validation | Failed on error |
| `check_result_not_null` | Must return non-null | Failed on null/error |
| `check_result_legacy_tolerant` | Legacy RPC may not support | Skipped on error |
| `check_data_consistency` | Compare Reth vs Legacy | Skipped if both return 403 |

### 7. Test Organization

Structure tests in phases:
1. **Basic Tests** - Single parameter, simple scenarios
2. **Boundary Tests** - Test around cutoff block
3. **Parameter Variant Tests** - Different parameter types (number/hash/tag)
4. **Consistency Tests** - Compare with Legacy RPC
5. **Edge Case Tests** - Invalid inputs, boundary values

### 8. Test Naming Convention

Use descriptive test names:
```bash
log_info "Test X.Y: <method> (<scenario>)"
```

Examples:
- `"Test 8.1.1: eth_getBalance (legacy BlockHash)"`
- `"Test 11.5: eth_getBlockByHash with all-zero hash"`
- `"Test 9.4.2: eth_getLogs (recent 50 blocks using 'latest')"`

### 9. Query Range Limits

For range queries like `eth_getLogs`:
- Keep ranges **≤ 100 blocks** to avoid timeouts
- Legacy RPC typically limits to 100-200 blocks
- Reth may limit result count (e.g., 20000 logs)
- Test cross-boundary with reasonable ranges

### 10. Legacy RPC Tolerance

Some methods may not be whitelisted on Legacy RPC:
- Use `check_result_legacy_tolerant` for these methods
- Expected behavior: Skip test if Legacy RPC returns 403
- Don't mark as failed - it's a Legacy RPC limitation, not Reth bug

### Quick Reference Checklist

For each new RPC method, verify:
- [ ] Valid data test (legacy + local)
- [ ] Invalid data test (non-existent)
- [ ] BlockNumber parameter (if supported)
- [ ] BlockHash parameter (if supported)
- [ ] BlockTag parameters: earliest, latest, pending (if supported)
- [ ] Cutoff boundary tests (cutoff-1, cutoff, cutoff+1)
- [ ] Data consistency test (Reth vs Legacy RPC)
- [ ] Edge cases (genesis, empty blocks, future blocks)
- [ ] Appropriate helper function selection
- [ ] Reasonable query ranges (if applicable)
