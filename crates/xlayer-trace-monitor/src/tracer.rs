use crate::{
    transaction::TransactionProcessId,
    utils::{Hash32, current_timestamp_ms, format_csv_line, format_hash_hex},
};

use crossbeam_channel::Sender;
use std::{
    fs::{self, File, OpenOptions},
    io::{BufWriter, Write},
    path::PathBuf,
    sync::{Arc, OnceLock},
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

#[derive(Debug)]
enum WriterMessage {
    Line(String),
    Flush(Option<Sender<Result<(), std::io::Error>>>),
    SyncAll(Option<Sender<Result<(), std::io::Error>>>),
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

        let (tx, rx) = crossbeam_channel::bounded(CHANNEL_CAPACITY);
        if enabled {
            thread::spawn(move || write_handle(rx, file_path));
        }

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
        if !self.is_enabled() {
            return Ok(());
        }

        let (ack_tx, ack_rx) = crossbeam_channel::bounded(1);
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
        if !self.is_enabled() {
            return Ok(());
        }

        let (ack_tx, ack_rx) = crossbeam_channel::bounded(1);
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

    /// Log transaction event at current time point
    pub fn log_transaction(
        &self,
        tx_hash: Hash32,
        process_id: TransactionProcessId,
        block_number: Option<u64>,
    ) {
        if !self.is_enabled() {
            return;
        }

        let timestamp_ms = current_timestamp_ms();
        let trace_hash = format_hash_hex(&tx_hash);

        let csv_line = format_csv_line(&trace_hash, process_id, timestamp_ms, None, block_number);

        self.send_line(csv_line);
    }

    /// Log block event at current time point
    pub fn log_block(
        &self,
        block_hash: Hash32,
        block_number: u64,
        process_id: TransactionProcessId,
    ) {
        if !self.is_enabled() {
            return;
        }

        let timestamp_ms = current_timestamp_ms();
        let trace_hash = format_hash_hex(&block_hash);

        let csv_line = format_csv_line(
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
        if !self.is_enabled() {
            return;
        }

        let trace_hash = format_hash_hex(&block_hash);

        let csv_line = format_csv_line(
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

    #[test]
    fn test_p2p_received_tx_identity() {
        let id = TransactionProcessId::P2pReceivedTx;
        assert_eq!(id.as_u64(), 15015);
        assert_eq!(id.as_str(), "xlayer_p2p_received_tx");
        assert_eq!(id.service_name(), "okx-defi-xlayer-rpcpay-pro");
        assert_ne!(id.service_name(), "okx-defi-xlayer-egseqz-pro");
    }

    #[test]
    fn test_existing_events_unchanged() {
        // IDs
        assert_eq!(TransactionProcessId::RpcReceiveTxEnd.as_u64(), 15010);
        assert_eq!(TransactionProcessId::SeqReceiveTxEnd.as_u64(), 15030);
        assert_eq!(TransactionProcessId::SeqBlockBuildStart.as_u64(), 15032);
        assert_eq!(TransactionProcessId::SeqTxExecutionEnd.as_u64(), 15034);
        assert_eq!(TransactionProcessId::SeqBlockBuildEnd.as_u64(), 15036);
        assert_eq!(TransactionProcessId::SeqBlockSendStart.as_u64(), 15042);
        assert_eq!(TransactionProcessId::RpcBlockReceiveEnd.as_u64(), 15060);
        assert_eq!(TransactionProcessId::RpcBlockInsertEnd.as_u64(), 15062);
        // Names
        assert_eq!(
            TransactionProcessId::RpcReceiveTxEnd.as_str(),
            "xlayer_rpc_receive_tx"
        );
        assert_eq!(
            TransactionProcessId::SeqReceiveTxEnd.as_str(),
            "xlayer_seq_receive_tx"
        );
        assert_eq!(
            TransactionProcessId::SeqBlockBuildStart.as_str(),
            "xlayer_seq_begin_block"
        );
        assert_eq!(
            TransactionProcessId::SeqTxExecutionEnd.as_str(),
            "xlayer_seq_package_tx"
        );
        assert_eq!(
            TransactionProcessId::SeqBlockBuildEnd.as_str(),
            "xlayer_seq_end_block"
        );
        assert_eq!(
            TransactionProcessId::SeqBlockSendStart.as_str(),
            "xlayer_seq_ds_sent"
        );
        assert_eq!(
            TransactionProcessId::RpcBlockReceiveEnd.as_str(),
            "xlayer_rpc_receive_block"
        );
        assert_eq!(
            TransactionProcessId::RpcBlockInsertEnd.as_str(),
            "xlayer_rpc_finish_block"
        );
        // None of the existing events uses the new id or name
        for id in [
            TransactionProcessId::RpcReceiveTxEnd,
            TransactionProcessId::SeqReceiveTxEnd,
            TransactionProcessId::SeqBlockBuildStart,
            TransactionProcessId::SeqTxExecutionEnd,
            TransactionProcessId::SeqBlockBuildEnd,
            TransactionProcessId::SeqBlockSendStart,
            TransactionProcessId::RpcBlockReceiveEnd,
            TransactionProcessId::RpcBlockInsertEnd,
        ] {
            assert_ne!(id.as_u64(), 15015);
            assert_ne!(id.as_str(), "xlayer_p2p_received_tx");
        }
    }

    #[test]
    fn test_p2p_received_tx_csv_row_without_block_height() {
        let (tracer, temp_dir, log_path) = setup_test_tracer(true);
        let tx_hash = [0xab; 32];
        tracer.log_transaction(tx_hash, TransactionProcessId::P2pReceivedTx, None);
        tracer.flush().unwrap();

        let content = fs::read_to_string(&log_path).unwrap();
        let line = content.lines().next().expect("one row expected");
        let fields: Vec<&str> = line.split(',').collect();
        assert_eq!(fields.len(), 23);
        assert_eq!(fields[7], "15015"); // col 8: numeric id
        assert_eq!(fields[8], "xlayer_p2p_received_tx"); // col 9: event name
        assert_eq!(fields[3], "okx-defi-xlayer-rpcpay-pro"); // col 4: service name
        assert_eq!(fields[14], ""); // col 15: block height empty
        assert_eq!(fields[15], ""); // col 16: block hash empty
        assert!(line.contains(&format_hash_hex(&tx_hash))); // tx hash present
        drop(temp_dir);
    }

    #[test]
    fn test_p2p_received_tx_csv_row_with_block_height() {
        let (tracer, temp_dir, log_path) = setup_test_tracer(true);
        let tx_hash = [0xcd; 32];
        tracer.log_transaction(tx_hash, TransactionProcessId::P2pReceivedTx, Some(987_654));
        tracer.flush().unwrap();

        let content = fs::read_to_string(&log_path).unwrap();
        let line = content.lines().next().expect("one row expected");
        let fields: Vec<&str> = line.split(',').collect();
        assert_eq!(fields.len(), 23);
        assert_eq!(fields[14], "987654"); // col 15: block height populated
        assert_eq!(fields[15], ""); // col 16: block hash still empty (tx-level event)
        drop(temp_dir);
    }

    #[test]
    fn test_p2p_received_tx_disabled_tracer_no_logging() {
        let (tracer, temp_dir, log_path) = setup_test_tracer(false);
        tracer.log_transaction([0xee; 32], TransactionProcessId::P2pReceivedTx, Some(1));
        tracer.flush().unwrap();
        if log_path.exists() {
            assert!(fs::read_to_string(&log_path).unwrap().is_empty());
        }
        drop(temp_dir);
    }
}
