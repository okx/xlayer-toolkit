//! Transaction tracing module for monitoring transaction lifecycle
//!
//! This module provides functionality to trace and log transaction lifecycle events
//! for monitoring and debugging purposes.
//!
//! Logging is non-blocking: log lines are sent to a dedicated writer thread via a bounded
//! channel, so callers (including async request handlers) never block on file I/O.

use crossbeam_channel::{bounded, Sender};
use std::{
    borrow::Cow,
    fs::{self, File, OpenOptions},
    io::{BufWriter, Write},
    path::PathBuf,
    sync::{
        mpsc,
        Arc, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    thread,
    time::Instant,
};

/// 32-byte hash (equivalent to B256)
pub type Hash32 = [u8; 32];

/// Format a 32-byte hash as hexadecimal string with 0x prefix
fn format_hash_hex(hash: &Hash32) -> String {
    format!("0x{}", hex::encode(hash))
}

/// Convert from B256 (alloy-primitives) or any 32-byte array to Hash32
///
/// This is a convenience function for converting from `alloy_primitives::B256` to `Hash32`.
/// Since B256 implements `AsRef<[u8; 32]>`, this conversion is zero-cost (just a reference copy).
///
/// # Example
///
/// ```rust
/// use xlayer_trace_monitor::{Hash32, from_b256};
///
/// // For [u8; 32], you can use it directly
/// let hash_array: Hash32 = [0x12; 32];
///
/// // If you use alloy_primitives::B256, convert like this:
/// # #[cfg(feature = "alloy")]
/// # {
/// # use alloy_primitives::B256;
/// # let b256_hash: B256 = B256::ZERO;
/// let hash32: Hash32 = from_b256(&b256_hash);
/// # }
/// ```
pub fn from_b256(b256: impl AsRef<[u8; 32]>) -> Hash32 {
    *b256.as_ref()
}

/// Capacity of the channel between log callers and the writer thread.
/// When full, new log lines are dropped to avoid blocking the caller.
const CHANNEL_CAPACITY: usize = 65_536;

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

/// Message sent from callers to the dedicated writer thread.
enum WriterMessage {
    /// A CSV line to append to the trace file.
    Line(String),
    /// Request flush; writer sends result on the given sender.
    Flush(Option<mpsc::Sender<Result<(), std::io::Error>>>),
    /// Request sync to disk; writer sends result on the given sender.
    SyncAll(Option<mpsc::Sender<Result<(), std::io::Error>>>),
}

/// Internal state for the transaction tracer
#[derive(Debug)]
struct TransactionTracerInner {
    /// Whether tracing is enabled
    enabled: bool,
    /// Channel to send log lines and control messages to the writer thread
    tx: Sender<WriterMessage>,
    /// Count of log lines dropped when the channel was full (for observability)
    dropped_count: AtomicU64,
}

/// Runs the dedicated writer thread: receives lines and control messages,
/// writes to file with BufWriter batching, and responds to flush/sync requests.
fn run_writer_thread(rx: crossbeam_channel::Receiver<WriterMessage>, file_path: PathBuf) {
    thread::spawn(move || {
        // Create parent directories if they don't exist
        if let Some(parent) = file_path.parent()
            && let Err(e) = fs::create_dir_all(parent)
        {
            tracing::warn!(
                target: "tx_trace",
                ?parent,
                error = %e,
                "Failed to create transaction trace output directory"
            );
        }

        let mut writer_opt: Option<BufWriter<File>> = match OpenOptions::new()
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
        };

        let mut write_count: u64 = 0;
        let mut last_flush_time = Instant::now();

        while let Ok(msg) = rx.recv() {
            match msg {
                WriterMessage::Line(csv_line) => {
                    if let Some(ref mut writer) = writer_opt {
                        if writeln!(writer, "{csv_line}").is_err() {
                            tracing::warn!(
                                target: "tx_trace",
                                "Failed to write to transaction trace file"
                            );
                        } else {
                            write_count += 1;
                            let now = Instant::now();
                            let time_since_flush = now.duration_since(last_flush_time);
                            let should_flush = write_count.is_multiple_of(FLUSH_INTERVAL_WRITES)
                                || time_since_flush.as_secs() >= FLUSH_INTERVAL_SECONDS;
                            if should_flush {
                                if writer.flush().is_err() {
                                    tracing::warn!(
                                        target: "tx_trace",
                                        "Failed to flush transaction trace file"
                                    );
                                }
                                last_flush_time = now;
                            }
                        }
                    }
                }
                WriterMessage::Flush(ack_tx) => {
                    let result = match &mut writer_opt {
                        Some(writer) => writer.flush(),
                        None => Ok(()),
                    };
                    if let Some(tx) = ack_tx {
                        let _ = tx.send(result);
                    }
                }
                WriterMessage::SyncAll(ack_tx) => {
                    let result = match &mut writer_opt {
                        Some(writer) => writer.flush().and_then(|()| writer.get_ref().sync_all()),
                        None => Ok(()),
                    };
                    if let Some(tx) = ack_tx {
                        let _ = tx.send(result);
                    }
                }
            }
        }
    });
}

/// Transaction tracer for logging transaction and block events
#[derive(Debug, Clone)]
pub struct TransactionTracer {
    inner: Arc<TransactionTracerInner>,
}

impl TransactionTracer {
    /// Create a new transaction tracer
    ///
    /// Log lines are sent to a dedicated writer thread via a bounded channel;
    /// callers never block on file I/O. When the channel is full, new lines are dropped.
    ///
    /// # Arguments
    /// * `enabled` - Whether tracing is enabled
    /// * `output_path` - Optional path to output file (defaults to `/data/logs/trace.log` if None)
    pub fn new(enabled: bool, output_path: Option<PathBuf>) -> Self {
        let default_path = PathBuf::from("/data/logs/trace.log");
        let final_path = output_path.unwrap_or(default_path);

        let file_path = if final_path.to_string_lossy().ends_with('/')
            || final_path.to_string_lossy().ends_with('\\')
            || (final_path.extension().is_none() && !final_path.exists())
        {
            final_path.join("trace.log")
        } else {
            final_path
        };

        let (tx, rx) = bounded(CHANNEL_CAPACITY);
        run_writer_thread(rx, file_path);

        Self {
            inner: Arc::new(TransactionTracerInner {
                enabled,
                tx,
                dropped_count: AtomicU64::new(0),
            }),
        }
    }

    /// Check if tracing is enabled
    pub fn is_enabled(&self) -> bool {
        self.inner.enabled
    }

    /// Number of log lines dropped because the writer channel was full.
    /// Useful for observability when tuning `CHANNEL_CAPACITY` or load.
    pub fn dropped_count(&self) -> u64 {
        self.inner.dropped_count.load(Ordering::Relaxed)
    }

    /// Enqueue a CSV line for the writer thread. Non-blocking; if the channel is full, the line is dropped.
    fn send_line(&self, csv_line: String) {
        match self.inner.tx.try_send(WriterMessage::Line(csv_line)) {
            Ok(()) => {}
            Err(crossbeam_channel::TrySendError::Full(line)) => {
                self.inner.dropped_count.fetch_add(1, Ordering::Relaxed);
                tracing::debug!(
                    target: "tx_trace",
                    dropped = self.inner.dropped_count.load(Ordering::Relaxed),
                    "Trace channel full, dropping log line"
                );
                drop(line);
            }
            Err(crossbeam_channel::TrySendError::Disconnected(_)) => {
                tracing::debug!(target: "tx_trace", "Writer thread disconnected");
            }
        }
    }

    /// Force flush the trace file.
    ///
    /// Sends a flush request to the writer thread and waits for completion.
    /// This ensures all buffered data is written to the OS (but not necessarily to disk).
    /// Use `sync_all()` if you need actual disk persistence.
    ///
    /// # Errors
    ///
    /// Returns an error if the writer is disconnected or if flushing fails.
    pub fn flush(&self) -> Result<(), std::io::Error> {
        let (ack_tx, ack_rx) = mpsc::channel();
        if self.inner.tx.send(WriterMessage::Flush(Some(ack_tx))).is_err() {
            return Err(std::io::Error::other(
                "Writer thread disconnected for transaction trace file",
            ));
        }
        ack_rx
            .recv()
            .map_err(|_| {
                std::io::Error::other("Writer thread did not acknowledge flush request")
            })?
    }

    /// Force sync the trace file to disk.
    ///
    /// Sends a sync request to the writer thread and waits for completion.
    /// This ensures all written data is persisted to disk, not just in OS page cache.
    /// Use this when you need strong durability guarantees (e.g., before shutdown).
    ///
    /// Note: This is more expensive than `flush()` but provides actual durability.
    ///
    /// # Errors
    ///
    /// Returns an error if the writer is disconnected or if flushing/syncing fails.
    pub fn sync_all(&self) -> Result<(), std::io::Error> {
        let (ack_tx, ack_rx) = mpsc::channel();
        if self
            .inner
            .tx
            .send(WriterMessage::SyncAll(Some(ack_tx)))
            .is_err()
        {
            return Err(std::io::Error::other(
                "Writer thread disconnected for transaction trace file",
            ));
        }
        ack_rx
            .recv()
            .map_err(|_| {
                std::io::Error::other("Writer thread did not acknowledge sync request")
            })?
    }

    /// Format CSV line with 23 fields.
    fn format_csv_line(
        trace: &str,
        process_id: TransactionProcessId,
        current_time: u128,
        block_hash: Option<Hash32>,
        block_number: Option<u64>,
    ) -> String {
        fn escape_csv(s: &str) -> Cow<'_, str> {
            if s.is_empty() {
                return Cow::Borrowed("");
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
        let block_hash_str = block_hash.map(|h| format_hash_hex(&h)).unwrap_or_default();

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
        tx_hash: Hash32,
        process_id: TransactionProcessId,
        block_number: Option<u64>,
    ) {
        if !self.inner.enabled {
            return;
        }

        let timestamp_ms = Self::current_timestamp_ms();
        let trace_hash = format_hash_hex(&tx_hash);

        let csv_line =
            Self::format_csv_line(&trace_hash, process_id, timestamp_ms, None, block_number);

        self.send_line(csv_line);
    }

    /// Log block event at current time point
    pub fn log_block(
        &self,
        block_hash: Hash32,
        block_number: u64,
        process_id: TransactionProcessId,
    ) {
        if !self.inner.enabled {
            return;
        }

        let timestamp_ms = Self::current_timestamp_ms();
        let trace_hash = format_hash_hex(&block_hash);

        let csv_line = Self::format_csv_line(
            &trace_hash,
            process_id,
            timestamp_ms,
            Some(block_hash),
            Some(block_number),
        );

        self.send_line(csv_line);
    }

    /// Log block event with a specific timestamp.
    ///
    /// This method is used when we need to log a block event with a timestamp
    /// that was saved earlier (e.g., when block building started but block hash
    /// was not yet available).
    pub fn log_block_with_timestamp(
        &self,
        block_hash: Hash32,
        block_number: u64,
        process_id: TransactionProcessId,
        timestamp_ms: u128,
    ) {
        if !self.inner.enabled {
            return;
        }

        let trace_hash = format_hash_hex(&block_hash);

        let csv_line = Self::format_csv_line(
            &trace_hash,
            process_id,
            timestamp_ms,
            Some(block_hash),
            Some(block_number),
        );

        self.send_line(csv_line);
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn setup_test_tracer(enabled: bool) -> (TransactionTracer, TempDir, PathBuf) {
        let temp_dir = TempDir::new().unwrap();
        let log_path = temp_dir.path().join("test_trace.log");
        let tracer = TransactionTracer::new(enabled, Some(log_path.clone()));
        (tracer, temp_dir, log_path)
    }

    #[test]
    fn test_tracer_initialization() {
        let (tracer, temp_dir, log_path) = setup_test_tracer(true);

        assert!(tracer.is_enabled());
        assert!(log_path.exists() || log_path.parent().unwrap().exists());

        // temp_dir will be automatically cleaned up when it goes out of scope
        drop(temp_dir);
    }

    #[test]
    fn test_tracer_disabled() {
        let (tracer, temp_dir, _log_path) = setup_test_tracer(false);

        assert!(!tracer.is_enabled());

        // temp_dir will be automatically cleaned up when it goes out of scope
        drop(temp_dir);
    }

    #[test]
    fn test_log_transaction() {
        let (tracer, temp_dir, log_path) = setup_test_tracer(true);

        let tx_hash = [0x12; 32];

        tracer.log_transaction(tx_hash, TransactionProcessId::SeqReceiveTxEnd, Some(12345));
        tracer.flush().unwrap();

        // Verify file was created and contains data
        assert!(log_path.exists());
        let content = fs::read_to_string(&log_path).unwrap();
        assert!(!content.is_empty());
        assert!(content.contains("xlayer_seq_receive_tx"));

        // temp_dir will be automatically cleaned up when it goes out of scope
        drop(temp_dir);
    }

    #[test]
    fn test_log_block() {
        let (tracer, temp_dir, log_path) = setup_test_tracer(true);

        let block_hash = [0x34; 32];

        tracer.log_block(block_hash, 12345, TransactionProcessId::SeqBlockBuildEnd);
        tracer.flush().unwrap();

        let content = fs::read_to_string(&log_path).unwrap();
        assert!(content.contains("xlayer_seq_end_block"));
        assert!(content.contains("12345"));

        // temp_dir will be automatically cleaned up when it goes out of scope
        drop(temp_dir);
    }

    #[test]
    fn test_log_block_with_timestamp() {
        let (tracer, temp_dir, _log_path) = setup_test_tracer(true);

        let block_hash = [0x56; 32];
        let timestamp = 1234567890123u128;

        tracer.log_block_with_timestamp(
            block_hash,
            12345,
            TransactionProcessId::SeqBlockBuildStart,
            timestamp,
        );
        tracer.flush().unwrap();

        // temp_dir will be automatically cleaned up when it goes out of scope
        drop(temp_dir);
    }

    #[test]
    fn test_multiple_process_ids() {
        let (tracer, temp_dir, log_path) = setup_test_tracer(true);

        let tx_hash = [0x78; 32];

        // Test different process IDs
        tracer.log_transaction(tx_hash, TransactionProcessId::RpcReceiveTxEnd, None);
        tracer.log_transaction(tx_hash, TransactionProcessId::SeqReceiveTxEnd, None);
        tracer.log_transaction(tx_hash, TransactionProcessId::SeqTxExecutionEnd, Some(100));
        tracer.flush().unwrap();

        let content = fs::read_to_string(&log_path).unwrap();
        assert!(content.contains("xlayer_rpc_receive_tx"));
        assert!(content.contains("xlayer_seq_receive_tx"));
        assert!(content.contains("xlayer_seq_package_tx"));

        // temp_dir will be automatically cleaned up when it goes out of scope
        drop(temp_dir);
    }

    #[test]
    fn test_service_name_mapping() {
        assert_eq!(
            TransactionProcessId::RpcReceiveTxEnd.service_name(),
            "okx-defi-xlayer-rpcpay-pro"
        );
        assert_eq!(
            TransactionProcessId::SeqReceiveTxEnd.service_name(),
            "okx-defi-xlayer-egseqz-pro"
        );
        assert_eq!(
            TransactionProcessId::SeqBlockBuildEnd.service_name(),
            "okx-defi-xlayer-egseqz-pro"
        );
    }

    #[test]
    fn test_process_id_conversions() {
        let process_id = TransactionProcessId::SeqReceiveTxEnd;
        assert_eq!(process_id.as_u64(), 15030);
        assert_eq!(process_id.as_str(), "xlayer_seq_receive_tx");
    }

    #[test]
    fn test_flush_and_sync() {
        let (tracer, temp_dir, _log_path) = setup_test_tracer(true);

        let tx_hash = [0x9a; 32];

        tracer.log_transaction(tx_hash, TransactionProcessId::SeqReceiveTxEnd, None);
        assert!(tracer.flush().is_ok());
        assert!(tracer.sync_all().is_ok());

        // temp_dir will be automatically cleaned up when it goes out of scope
        drop(temp_dir);
    }

    #[test]
    fn test_disabled_tracer_no_logging() {
        let (tracer, temp_dir, log_path) = setup_test_tracer(false);

        let tx_hash = [0xbc; 32];

        // Should not log when disabled
        tracer.log_transaction(tx_hash, TransactionProcessId::SeqReceiveTxEnd, None);
        tracer.flush().unwrap();

        // File should not exist or be empty
        if log_path.exists() {
            let content = fs::read_to_string(&log_path).unwrap();
            assert!(content.is_empty());
        }

        // temp_dir will be automatically cleaned up when it goes out of scope
        drop(temp_dir);
    }

    #[test]
    fn test_default_path() {
        // Test that custom path logic works
        let temp_dir = TempDir::new().unwrap();
        let custom_path = temp_dir.path().join("custom.log");
        let tracer = TransactionTracer::new(true, Some(custom_path.clone()));

        assert!(tracer.is_enabled());

        // temp_dir will be automatically cleaned up when it goes out of scope
        drop(temp_dir);
    }
}
