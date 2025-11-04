# XLayer Legacy RPC Implementation

Based on [op-geth migration RPC implementation](https://github.com/okx/op-geth/pull/16)

## Parameters

| Parameter | Description |
|-----------|-------------|
| `--legacy-rpc-url` | URL of the legacy Erigon RPC endpoint |
| `--legacy-cutoff-block` | Block number where migration occurred. Blocks below this are fetched from legacy RPC |
| `--legacy-rpc-timeout` | Timeout for legacy RPC requests in seconds |

## API Implementation Status

| # | RPC Method | Status | Note |
|---|------------|--------|------|
| 1 | `eth_getBlockByNumber` | ✅ | |
| 2 | `eth_getBlockByHash` | ✅ | |
| 3 | `eth_getHeaderByNumber` | ⚠️ | Legacy doesn't support |
| 4 | `eth_getHeaderByHash` | ⚠️ | Legacy doesn't support |
| 5 | `eth_getBlockReceipts` | ✅ | |
| 6 | `eth_getBlockTransactionCountByNumber` | ✅ | |
| 7 | `eth_getBlockTransactionCountByHash` | ✅ | |
| 8 | `eth_getTransactionByHash` | ✅ | |
| 9 | `eth_getTransactionReceipt` | ✅ | |
| 10 | `eth_getTransactionByBlockHashAndIndex` | ✅ | |
| 11 | `eth_getTransactionByBlockNumberAndIndex` | ✅ | |
| 12 | `eth_getRawTransactionByHash` | ✅ | |
| 13 | `eth_getRawTransactionByBlockHashAndIndex` | ✅ | |
| 14 | `eth_getRawTransactionByBlockNumberAndIndex` | ✅ | |
| 15 | `eth_getBalance` | ✅ | |
| 16 | `eth_getCode` | ✅ | |
| 17 | `eth_getStorageAt` | ✅ | |
| 18 | `eth_getTransactionCount` | ✅ | |
| 19 | `eth_getLogs` | ✅ | |
| 20 | `eth_newFilter` | ❌ | Real-time query only |
| 21 | `eth_getFilterLogs` | ❌ | Real-time query only |
| 22 | `eth_getFilterChanges` | ❌ | Real-time query only |
| 23 | `eth_uninstallFilter` | ❌ | Real-time query only |
| 24 | `eth_getBlockInternalTransactions` | 🔄 | TODO |
| 25 | `eth_getInternalTransactions` | 🔄 | TODO |