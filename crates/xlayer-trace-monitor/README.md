# xlayer-trace-monitor

Transaction and block tracing monitor crate for X Layer.

## Overview

`xlayer-trace-monitor` is a standalone crate that provides transaction and block lifecycle monitoring functionality. It implements a singleton pattern for global tracer management and supports logging to CSV files.

## Features

- **Singleton Initialization**: Global tracer instance managed via `OnceLock`
- **8 Monitoring Points**: Complete coverage of transaction and block lifecycle
- **CSV Output**: Structured logging with 23 fields
- **Automatic Flushing**: Periodic flush to ensure data persistence
- **Zero Overhead**: No performance impact when disabled
- **Default Path**: Automatically uses `/data/logs/trace.log` if no path specified

## Usage

### 1. Add Dependency

In your `Cargo.toml`:

```toml
[dependencies]
xlayer-trace-monitor = { path = "../xlayer-toolkit/crates/xlayer-trace-monitor" }
# Or from git:
# xlayer-trace-monitor = { git = "https://github.com/okx/xlayer-toolkit", path = "crates/xlayer-trace-monitor" }
```

### 2. Initialize Global Tracer

```rust
use xlayer_trace_monitor::{init_global_tracer, NodeType};
use std::path::PathBuf;

// Initialize at application startup
init_global_tracer(
    true,  // enabled
    Some(PathBuf::from("/path/to/trace.log")),  // output path (optional, defaults to /data/logs/trace.log)
    NodeType::Sequencer,  // or NodeType::Rpc, NodeType::Unknown
);

// Or use default path:
init_global_tracer(
    true,
    None,  // Will use /data/logs/trace.log
    NodeType::Sequencer,
);
```

### 3. Use in Code

```rust
use xlayer_trace_monitor::{get_global_tracer, TransactionProcessId};
use alloy_primitives::B256;

// Log transaction event
if let Some(tracer) = get_global_tracer() {
    tracer.log_transaction(
        tx_hash,  // B256
        TransactionProcessId::SeqTxExecutionEnd,
        Some(block_number),
    );
}

// Log block event
if let Some(tracer) = get_global_tracer() {
    tracer.log_block(
        block_hash,  // B256
        block_number,
        TransactionProcessId::SeqBlockBuildEnd,
    );
}

// Log block event with saved timestamp
let build_start_timestamp = std::time::SystemTime::now()
    .duration_since(std::time::UNIX_EPOCH)
    .unwrap_or_default()
    .as_millis();
// ... later, when block hash is available ...
if let Some(tracer) = get_global_tracer() {
    tracer.log_block_with_timestamp(
        block_hash,
        block_number,
        TransactionProcessId::SeqBlockBuildStart,
        build_start_timestamp,
    );
}
```

## Monitoring Points

| ID | Enum | Description |
|----|------|-------------|
| 15010 | `RpcReceiveTxEnd` | RPC node received transaction |
| 15030 | `SeqReceiveTxEnd` | Sequencer node received transaction |
| 15032 | `SeqBlockBuildStart` | Sequencer started building block |
| 15034 | `SeqTxExecutionEnd` | Sequencer completed transaction execution |
| 15036 | `SeqBlockBuildEnd` | Sequencer completed building block |
| 15042 | `SeqBlockSendStart` | Sequencer started sending block |
| 15060 | `RpcBlockReceiveEnd` | RPC node received block |
| 15062 | `RpcBlockInsertEnd` | RPC node completed block insertion |

## API Reference

### Functions

- `init_global_tracer(enabled, output_path, node_type)` - Initialize singleton tracer
- `get_global_tracer()` - Get global tracer instance (returns `None` if not initialized)
- `flush_global_tracer()` - Force flush trace file

### Types

- `TransactionTracer` - Main tracer struct
- `TransactionProcessId` - Enum for monitoring point IDs
- `NodeType` - Enum for node type (Sequencer, Rpc, Unknown)

### Methods

- `tracer.log_transaction(tx_hash, process_id, block_number)` - Log transaction event
- `tracer.log_block(block_hash, block_number, process_id)` - Log block event
- `tracer.log_block_with_timestamp(...)` - Log block with specific timestamp
- `tracer.flush()` - Force flush trace file
- `tracer.is_enabled()` - Check if tracing is enabled

## CSV Format

The output CSV contains 23 fields:
1. Chain name
2. Trace hash
3. Status
4. Service name
5. Business name
6. Client
7. Chain ID
8. Process ID (numeric)
9. Process name
10. Index
11. Inner index
12. Current time (milliseconds)
13. Refer ID
14. Contract address
15. Block height
16. Block hash
17. Block time
18. Deposit confirm height
19. Token ID
20. MEV supplier
21. Business hash
22. Transaction type
23. Extension JSON

## Default Behavior

- **Default Output Path**: If `output_path` is `None`, the tracer will use `/data/logs/trace.log`
- **File Creation**: Parent directories are automatically created if they don't exist
- **Append Mode**: Files are opened in append mode, existing content is preserved
- **Auto Flush**: Automatic flush occurs every 100 writes or 1 second
- **Zero Overhead**: When disabled, all logging methods return early (no performance impact)

## Notes

- The tracer must be initialized before use
- If not initialized, `get_global_tracer()` returns `None` and logging is skipped
- When disabled, all logging methods return early (zero overhead)
- File is opened in append mode, existing content is preserved
- Automatic flush occurs every 100 writes or 1 second
- All logs are written to file only, never to console

## License

MIT OR Apache-2.0

