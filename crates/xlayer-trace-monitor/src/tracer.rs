use crate::{
    constants::{BUSINESS_NAME, CHAIN_ID, CHAIN_NAME},
    transaction::TransactionProcessId,
    utils::{Hash32, format_hash_hex},
};

use crossbeam_channel::{Sender, bounded};
use std::{
    borrow::Cow,
    fs::{self, File, OpenOptions},
    io::{BufWriter, Write},
    path::PathBuf,
    sync::{Arc, OnceLock, mpsc},
    thread,
    time::Instant,
};

/// Capacity of the channel between log callers and the writer thread.
/// When full, new log lines are dropped to avoid blocking the caller.
const CHANNEL_CAPACITY: usize = 65_536;

/// Number of log entries to write before forcing a flush.
/// This reduces system calls by batching writes through `BufWriter`.
const FLUSH_INTERVAL_WRITES: u64 = 100;

/// Time interval between flushes (in seconds)
/// Ensures data is periodically persisted even if write count is low
const FLUSH_INTERVAL_SECONDS: u64 = 1;

static GLOBAL_TRACER: OnceLock<Arc<TransactionTracer>> = OnceLock::new();

/// Initialize the global tracer. Call once at startup. First call wins; later calls ignored.
pub fn init_global_tracer(enabled: bool, output_path: Option<PathBuf>) {
    let tracer = TransactionTracer::new(enabled, output_path);
    GLOBAL_TRACER.set(Arc::new(tracer)).ok();
}

/// Get the global tracer, or `None` if not initialized.
pub fn get_global_tracer() -> Option<Arc<TransactionTracer>> {
    GLOBAL_TRACER.get().cloned()
}

/// Flush the global tracer buffer to the OS.
pub fn flush_global_tracer() -> Result<(), std::io::Error> {
    if let Some(tracer) = get_global_tracer() {
        tracer.flush()
    } else {
        Ok(())
    }
}

/// Sync the global tracer to disk. Call before process exit to avoid losing buffered data.
pub fn sync_global_tracer() -> Result<(), std::io::Error> {
    if let Some(tracer) = get_global_tracer() {
        tracer.sync_all()
    } else {
        Ok(())
    }
}

enum WriterMessage {
    Line(String),
    Flush(Option<mpsc::Sender<Result<(), std::io::Error>>>),
    SyncAll(Option<mpsc::Sender<Result<(), std::io::Error>>>),
}

#[derive(Debug, Clone)]
pub struct TransactionTracer {
    inner: Arc<TransactionTracerInner>,
}

impl TransactionTracer {
    /// Create a new tracer. Logs are sent to a writer thread via a bounded channel; callers never block.
    /// Default path: `/data/logs/trace.log`.
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
        write_handle(rx, file_path);

        Self {
            inner: Arc::new(TransactionTracerInner { enabled, tx }),
        }
    }

    /// Check if tracing is enabled
    pub fn is_enabled(&self) -> bool {
        self.inner.enabled
    }

    fn send_line(&self, csv_line: String) {
        let _ = self.inner.tx.try_send(WriterMessage::Line(csv_line));
    }

    /// Flush buffer to the OS. Use `sync_all()` for disk persistence.
    pub fn flush(&self) -> Result<(), std::io::Error> {
        let (ack_tx, ack_rx) = mpsc::channel();
        if self
            .inner
            .tx
            .send(WriterMessage::Flush(Some(ack_tx)))
            .is_err()
        {
            return Err(std::io::Error::other(
                "Writer thread disconnected for transaction trace file",
            ));
        }
        ack_rx
            .recv()
            .map_err(|_| std::io::Error::other("Writer thread did not acknowledge flush request"))?
    }

    /// Sync to disk. Call before shutdown to persist buffered data.
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
            .map_err(|_| std::io::Error::other("Writer thread did not acknowledge sync request"))?
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

    /// Log block event with a given timestamp (e.g. when block building started but hash was not yet available).
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

#[derive(Debug)]
struct TransactionTracerInner {
    enabled: bool,
    tx: Sender<WriterMessage>,
}

fn write_handle(rx: crossbeam_channel::Receiver<WriterMessage>, file_path: PathBuf) {
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
