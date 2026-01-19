//! Transaction tracing module for monitoring transaction lifecycle
//!
//! This module provides functionality to trace and log transaction lifecycle events
//! for monitoring and debugging purposes.

use alloy_primitives::B256;
use std::{
    borrow::Cow,
    fs::{self, File, OpenOptions},
    io::{BufWriter, Write},
    path::PathBuf,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    time::Instant,
};

/// Number of log entries to write before forcing a flush.
/// This reduces system calls by batching writes through `BufWriter`.
const FLUSH_INTERVAL_WRITES: u64 = 100;

/// Time interval between flushes (in seconds)
/// Ensures data is periodically persisted even if write count is low
const FLUSH_INTERVAL_SECONDS: u64 = 1;

/// Fixed chain name
const CHAIN_NAME: &str = "X Layer";

/// Fixed business name
const BUSINESS_NAME: &str = "X Layer";

/// Fixed chain ID
const CHAIN_ID: &str = "196";

/// RPC service name
const RPC_SERVICE_NAME: &str = "okx-defi-xlayer-rpcpay-pro";

/// Sequencer service name
const SEQ_SERVICE_NAME: &str = "okx-defi-xlayer-egseqz-pro";

/// Transaction process ID for tracking different stages in the transaction lifecycle
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TransactionProcessId {
    /// RPC node: Transaction received and ready to forward
    RpcReceiveTxEnd = 15010,

    /// Sequencer node: Transaction received and added to pool
    SeqReceiveTxEnd = 15030,

    /// Sequencer node: Block building started
    SeqBlockBuildStart = 15032,

    /// Sequencer node: Transaction execution completed
    SeqTxExecutionEnd = 15034,

    /// Sequencer node: Block building completed
    SeqBlockBuildEnd = 15036,

    /// Sequencer node: Block sending started
    SeqBlockSendStart = 15042,

    /// RPC node: Block received from sequencer
    RpcBlockReceiveEnd = 15060,

    /// RPC node: Block insertion completed
    RpcBlockInsertEnd = 15062,
}

impl TransactionProcessId {
    /// Returns the string representation of the process ID.
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::RpcReceiveTxEnd => "xlayer_rpc_receive_tx",
            Self::SeqReceiveTxEnd => "xlayer_seq_receive_tx",
            Self::SeqBlockBuildStart => "xlayer_seq_begin_block",
            Self::SeqTxExecutionEnd => "xlayer_seq_package_tx",
            Self::SeqBlockBuildEnd => "xlayer_seq_end_block",
            Self::SeqBlockSendStart => "xlayer_seq_ds_sent",
            Self::RpcBlockReceiveEnd => "xlayer_rpc_receive_block",
            Self::RpcBlockInsertEnd => "xlayer_rpc_finish_block",
        }
    }

    /// Returns the numeric ID of the process.
    pub const fn as_u64(&self) -> u64 {
        *self as u64
    }

    /// Returns the service name based on the process ID.
    pub const fn service_name(&self) -> &'static str {
        match self {
            // RPC-related process IDs
            Self::RpcReceiveTxEnd | Self::RpcBlockReceiveEnd | Self::RpcBlockInsertEnd => {
                RPC_SERVICE_NAME
            }

            // Sequencer-related process IDs
            Self::SeqReceiveTxEnd
            | Self::SeqBlockBuildStart
            | Self::SeqTxExecutionEnd
            | Self::SeqBlockBuildEnd
            | Self::SeqBlockSendStart => SEQ_SERVICE_NAME,
        }
    }
}

/// Internal state for the transaction tracer
#[derive(Debug)]
struct TransactionTracerInner {
    /// Whether tracing is enabled
    enabled: bool,
    /// Buffered file writer for efficient batch writes
    output_file: Mutex<Option<BufWriter<File>>>,
    /// Counter for number of writes since last flush
    write_count: AtomicU64,
    /// Last flush time
    last_flush_time: Mutex<Instant>,
}

/// Transaction tracer for logging transaction and block events
#[derive(Debug, Clone)]
pub struct TransactionTracer {
    inner: Arc<TransactionTracerInner>,
}

impl TransactionTracer {
    /// Create a new transaction tracer
    ///
    /// # Arguments
    /// * `enabled` - Whether tracing is enabled
    /// * `output_path` - Optional path to output file (defaults to `/data/logs/trace.log` if None)
    pub fn new(enabled: bool, output_path: Option<PathBuf>) -> Self {
        // Default path if not specified: /data/logs/trace.log
        let default_path = PathBuf::from("/data/logs/trace.log");
        let final_path = output_path.unwrap_or(default_path);

        let output_file = {
            let file_path = if final_path.to_string_lossy().ends_with('/')
                || final_path.to_string_lossy().ends_with('\\')
                || (final_path.extension().is_none() && !final_path.exists())
            {
                final_path.join("trace.log")
            } else {
                final_path
            };

            // Create parent directories if they don't exist
            if let Some(parent) = file_path.parent() {
                if let Err(e) = fs::create_dir_all(parent) {
                    tracing::warn!(
                        target: "tx_trace",
                        ?parent,
                        error = %e,
                        "Failed to create transaction trace output directory"
                    );
                }
            }

            match OpenOptions::new()
                .create(true)
                .append(true)
                .open(&file_path)
            {
                Ok(file) => {
                    tracing::info!(
                        target: "tx_trace",
                        ?file_path,
                        "Transaction trace file opened for appending"
                    );
                    // Use BufWriter for efficient batch writes
                    // Default buffer size is 8KB, which is good for our use case
                    Some(BufWriter::new(file))
                }
                Err(e) => {
                    tracing::warn!(
                        target: "tx_trace",
                        ?file_path,
                        error = %e,
                        "Failed to open transaction trace file"
                    );
                    None
                }
            }
        };

        Self {
            inner: Arc::new(TransactionTracerInner {
                enabled,
                output_file: Mutex::new(output_file),
                write_count: AtomicU64::new(0),
                last_flush_time: Mutex::new(Instant::now()),
            }),
        }
    }

    /// Check if tracing is enabled
    pub fn is_enabled(&self) -> bool {
        self.inner.enabled
    }

    /// Write CSV line to trace file with periodic flush.
    ///
    /// Uses `BufWriter` to batch writes, reducing system calls for better performance.
    /// Automatically flushes every `FLUSH_INTERVAL_WRITES` writes or `FLUSH_INTERVAL_SECONDS`.
    fn write_to_file(&self, csv_line: &str) {
        match self.inner.output_file.lock() {
            Ok(mut file_guard) => {
                if let Some(ref mut writer) = *file_guard {
                    if let Err(e) = writeln!(writer, "{csv_line}") {
                        tracing::warn!(
                            target: "tx_trace",
                            error = %e,
                            "Failed to write to transaction trace file"
                        );
                    } else {
                        let count = self.inner.write_count.fetch_add(1, Ordering::Relaxed) + 1;

                        let should_flush = {
                            match self.inner.last_flush_time.lock() {
                                Ok(mut last_flush) => {
                                    let now = Instant::now();
                                    let time_since_flush = now.duration_since(*last_flush);

                                    if count.is_multiple_of(FLUSH_INTERVAL_WRITES)
                                        || time_since_flush.as_secs() >= FLUSH_INTERVAL_SECONDS
                                    {
                                        *last_flush = now;
                                        true
                                    } else {
                                        false
                                    }
                                }
                                Err(_) => {
                                    // If lock is poisoned, still flush to ensure data safety
                                    true
                                }
                            }
                        };

                        if should_flush && let Err(e) = writer.flush() {
                            tracing::warn!(
                                target: "tx_trace",
                                error = %e,
                                "Failed to flush transaction trace file"
                            );
                        }
                    }
                }
            }
            Err(e) => {
                tracing::warn!(
                    target: "tx_trace",
                    error = %e,
                    "Failed to acquire lock for transaction trace file"
                );
            }
        }
    }

    /// Force flush the trace file.
    ///
    /// Flushes the `BufWriter` buffer to the underlying file.
    /// This ensures all buffered data is written to the OS (but not necessarily to disk).
    /// Use `sync_all()` if you need actual disk persistence.
    ///
    /// # Errors
    ///
    /// Returns an error if the lock cannot be acquired or if flushing fails.
    pub fn flush(&self) -> Result<(), std::io::Error> {
        match self.inner.output_file.lock() {
            Ok(mut file_guard) => {
                if let Some(ref mut writer) = *file_guard {
                    writer.flush()
                } else {
                    Ok(())
                }
            }
            Err(_) => Err(std::io::Error::other(
                "Failed to acquire lock for flushing transaction trace file",
            )),
        }
    }

    /// Force sync the trace file to disk.
    ///
    /// First flushes the `BufWriter` buffer, then syncs to disk.
    /// This ensures all written data is persisted to disk, not just in OS page cache.
    /// Use this when you need strong durability guarantees (e.g., before shutdown).
    ///
    /// Note: This is more expensive than `flush()` but provides actual durability.
    ///
    /// # Errors
    ///
    /// Returns an error if the lock cannot be acquired or if flushing/syncing fails.
    pub fn sync_all(&self) -> Result<(), std::io::Error> {
        match self.inner.output_file.lock() {
            Ok(mut file_guard) => {
                if let Some(ref mut writer) = *file_guard {
                    // First flush the buffer
                    writer.flush()?;
                    // Then get the underlying file and sync
                    writer.get_ref().sync_all()
                } else {
                    Ok(())
                }
            }
            Err(_) => Err(std::io::Error::other(
                "Failed to acquire lock for syncing transaction trace file",
            )),
        }
    }

    /// Format CSV line with 23 fields.
    fn format_csv_line(
        trace: &str,
        process_id: TransactionProcessId,
        current_time: u128,
        block_hash: Option<B256>,
        block_number: Option<u64>,
    ) -> String {
        fn escape_csv(s: &str) -> Cow<'_, str> {
            if s.is_empty() {
                return String::new();
            }

            if s.contains(',') || s.contains('"') || s.contains('\n') {
                Cow::Owned(format!("\"{}\"", s.replace('"', "\"\"")))
            } else {
                Cow::Borrowed(s)
            }
        }

        // Pre-compute values that need conversion
        let process_str = process_id.as_u64().to_string();
        let current_time_str = current_time.to_string();
        let block_height = block_number.map(|n| n.to_string()).unwrap_or_default();
        let block_hash_str = block_hash.map(|h| format!("{h:#x}")).unwrap_or_default();

        // Build CSV line efficiently
        format!(
            "{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}",
            escape_csv(CHAIN_NAME),
            escape_csv(trace),
            "", // status_str (empty, no need to escape)
            escape_csv(process_id.service_name()),
            escape_csv(BUSINESS_NAME),
            "", // client (empty)
            escape_csv(CHAIN_ID),
            escape_csv(&process_str),
            escape_csv(process_id.as_str()),
            "", // index (empty)
            "", // inner_index (empty)
            escape_csv(&current_time_str),
            "", // referld (empty)
            "", // contract_address (empty)
            escape_csv(&block_height),
            escape_csv(&block_hash_str),
            "", // block_time (empty)
            "", // deposit_confirm_height (empty)
            "", // token_id (empty)
            "", // mev_supplier (empty)
            "", // business_hash (empty)
            "", // transaction_type (empty)
            ""  // ext_json (empty)
        )
    }

    /// Get current timestamp in milliseconds since UNIX epoch
    fn current_timestamp_ms() -> u128 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
    }

    /// Log transaction event at current time point
    pub fn log_transaction(
        &self,
        tx_hash: B256,
        process_id: TransactionProcessId,
        block_number: Option<u64>,
    ) {
        if !self.inner.enabled {
            return;
        }

        let timestamp_ms = Self::current_timestamp_ms();
        let trace_hash = format!("{tx_hash:#x}");

        let csv_line =
            Self::format_csv_line(&trace_hash, process_id, timestamp_ms, None, block_number);

        self.write_to_file(&csv_line);
    }

    /// Log block event at current time point
    pub fn log_block(&self, block_hash: B256, block_number: u64, process_id: TransactionProcessId) {
        if !self.inner.enabled {
            return;
        }

        let timestamp_ms = Self::current_timestamp_ms();
        let trace_hash = format!("{block_hash:#x}");

        let csv_line = Self::format_csv_line(
            &trace_hash,
            process_id,
            timestamp_ms,
            Some(block_hash),
            Some(block_number),
        );

        self.write_to_file(&csv_line);
    }

    /// Log block event with a specific timestamp.
    ///
    /// This method is used when we need to log a block event with a timestamp
    /// that was saved earlier (e.g., when block building started but block hash
    /// was not yet available).
    pub fn log_block_with_timestamp(
        &self,
        block_hash: B256,
        block_number: u64,
        process_id: TransactionProcessId,
        timestamp_ms: u128,
    ) {
        if !self.inner.enabled {
            return;
        }

        let trace_hash = format!("{block_hash:#x}");

        let csv_line = Self::format_csv_line(
            &trace_hash,
            process_id,
            timestamp_ms,
            Some(block_hash),
            Some(block_number),
        );

        self.write_to_file(&csv_line);
    }
}

/// Global transaction tracer instance (singleton).
static GLOBAL_TRACER: OnceLock<Arc<TransactionTracer>> = OnceLock::new();

/// Initialize the global transaction tracer
///
/// This function should be called once at application startup to initialize
/// the singleton tracer instance. Subsequent calls will be ignored.
///
/// # Arguments
/// * `enabled` - Whether tracing is enabled (from `--tx-trace.enable` flag)
/// * `output_path` - Output file path (from `--tx-trace.output-path` flag, defaults to `/data/logs/trace.log` if None)
pub fn init_global_tracer(enabled: bool, output_path: Option<PathBuf>) {
    let tracer = TransactionTracer::new(enabled, output_path);
    GLOBAL_TRACER.set(Arc::new(tracer)).ok();
}

/// Get the global transaction tracer
///
/// Returns `None` if the tracer has not been initialized yet.
pub fn get_global_tracer() -> Option<Arc<TransactionTracer>> {
    GLOBAL_TRACER.get().cloned()
}

/// Flush the global transaction tracer.
///
/// Flushes the `BufWriter` buffer to ensure all buffered data is written to the OS.
/// This is called automatically during normal operation, but you can call it manually
/// if you need to ensure data is written immediately.
pub fn flush_global_tracer() -> Result<(), std::io::Error> {
    if let Some(tracer) = get_global_tracer() {
        tracer.flush()
    } else {
        Ok(())
    }
}

/// Sync the global transaction tracer to disk.
///
/// Forces a sync of the trace file to ensure all data is persisted to disk.
/// Use this when you need strong durability guarantees (e.g., before shutdown).
pub fn sync_global_tracer() -> Result<(), std::io::Error> {
    if let Some(tracer) = get_global_tracer() {
        tracer.sync_all()
    } else {
        Ok(())
    }
}
