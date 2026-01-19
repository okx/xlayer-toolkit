//! Transaction tracing module for monitoring transaction lifecycle
//!
//! This module provides functionality to trace and log transaction lifecycle events
//! for monitoring and debugging purposes.

use alloy_primitives::B256;
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::Instant,
};

/// Number of log entries to write before forcing a flush
const FLUSH_INTERVAL_WRITES: u64 = 100;

/// Time interval between flushes (in seconds)
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

/// Node type for identifying sequencer vs RPC node
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeType {
    /// Sequencer node (builds blocks)
    Sequencer,
    /// RPC node (forwards transactions to sequencer)
    Rpc,
    /// Unknown node type (default)
    Unknown,
}

impl NodeType {
    /// Returns the string representation of the node type
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Sequencer => "sequencer",
            Self::Rpc => "rpc",
            Self::Unknown => "unknown",
        }
    }
}

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
    /// Returns the string representation of the process ID
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

    /// Returns the numeric ID of the process
    pub const fn as_u64(&self) -> u64 {
        *self as u64
    }

    /// Returns the service name based on the process ID
    pub const fn service_name(&self) -> &'static str {
        match self {
            // RPC-related process IDs
            Self::RpcReceiveTxEnd | Self::RpcBlockReceiveEnd | Self::RpcBlockInsertEnd => {
                RPC_SERVICE_NAME
            }

            // Sequencer-related process IDs
            Self::SeqReceiveTxEnd |
            Self::SeqBlockBuildStart |
            Self::SeqTxExecutionEnd |
            Self::SeqBlockBuildEnd |
            Self::SeqBlockSendStart => SEQ_SERVICE_NAME,
        }
    }
}

/// Internal state for the transaction tracer
#[derive(Debug)]
struct TransactionTracerInner {
    /// Whether tracing is enabled
    enabled: bool,
    /// Output file path (if None, logs to console only)
    #[allow(dead_code)]
    output_path: Option<PathBuf>,
    /// File handle for writing logs
    output_file: Mutex<Option<File>>,
    /// Node type (Sequencer, Rpc, or Unknown)
    #[allow(dead_code)]
    node_type: NodeType,
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
    pub fn new(enabled: bool, output_path: Option<PathBuf>, node_type: NodeType) -> Self {
        // Default path if not specified: /data/logs/trace.log
        let default_path = PathBuf::from("/data/logs/trace.log");
        let final_path = output_path.unwrap_or(default_path);

        let output_file = {
            let file_path = if final_path.to_string_lossy().ends_with('/') ||
                final_path.to_string_lossy().ends_with('\\') ||
                (final_path.extension().is_none() && !final_path.exists())
            {
                final_path.join("trace.log")
            } else {
                final_path.clone()
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

            match OpenOptions::new().create(true).append(true).open(&file_path) {
                Ok(file) => {
                    tracing::info!(
                        target: "tx_trace",
                        ?file_path,
                        "Transaction trace file opened for appending"
                    );
                    Some(file)
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
                output_path: Some(final_path),
                output_file: Mutex::new(output_file),
                node_type,
                write_count: AtomicU64::new(0),
                last_flush_time: Mutex::new(Instant::now()),
            }),
        }
    }

    /// Check if tracing is enabled
    pub fn is_enabled(&self) -> bool {
        self.inner.enabled
    }

    /// Write CSV line to trace file with periodic flush
    fn write_to_file(&self, csv_line: &str) {
        match self.inner.output_file.lock() {
            Ok(mut file_guard) => {
                if let Some(ref mut file) = *file_guard {
                    if let Err(e) = writeln!(file, "{csv_line}") {
                        tracing::warn!(
                            target: "tx_trace",
                            error = %e,
                            "Failed to write to transaction trace file"
                        );
                    } else {
                        let count = self.inner.write_count.fetch_add(1, Ordering::Relaxed) + 1;

                        let should_flush = {
                            let mut last_flush = self.inner.last_flush_time.lock().unwrap();
                            let now = Instant::now();
                            let time_since_flush = now.duration_since(*last_flush);

                            if count.is_multiple_of(FLUSH_INTERVAL_WRITES) ||
                                time_since_flush.as_secs() >= FLUSH_INTERVAL_SECONDS
                            {
                                *last_flush = now;
                                true
                            } else {
                                false
                            }
                        };

                        if should_flush {
                            if let Err(e) = file.flush() {
                                tracing::warn!(
                                    target: "tx_trace",
                                    error = %e,
                                    "Failed to flush transaction trace file"
                                );
                            }
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

    /// Force flush the trace file
    pub fn flush(&self) {
        match self.inner.output_file.lock() {
            Ok(mut file_guard) => {
                if let Some(ref mut file) = *file_guard {
                    if let Err(e) = file.flush() {
                        tracing::warn!(
                            target: "tx_trace",
                            error = %e,
                            "Failed to flush transaction trace file on shutdown"
                        );
                    }
                }
            }
            Err(e) => {
                tracing::warn!(
                    target: "tx_trace",
                    error = %e,
                    "Failed to acquire lock for flushing transaction trace file"
                );
            }
        }
    }

    /// Format CSV line with 23 fields
    fn format_csv_line(
        &self,
        trace: &str,
        process_id: TransactionProcessId,
        current_time: u128,
        block_hash: Option<B256>,
        block_number: Option<u64>,
    ) -> String {
        let escape_csv = |s: &str| -> String {
            if s.contains(',') || s.contains('"') || s.contains('\n') {
                format!("\"{}\"", s.replace('"', "\"\""))
            } else {
                s.to_string()
            }
        };

        let chain = CHAIN_NAME;
        let trace_hash = trace.to_lowercase();
        let status_str = "";
        let service_name = process_id.service_name();
        let business = BUSINESS_NAME;
        let client = "";
        let chainld = CHAIN_ID;
        let process_str = (process_id as u32).to_string();
        let process_word_str = process_id.as_str();
        let index = "";
        let inner_index = "";
        let current_time_str = current_time.to_string();
        let referld = "";
        let contract_address = "";
        let block_height = block_number.map(|n| n.to_string()).unwrap_or_default();
        let block_hash_str =
            block_hash.map(|h| format!("{h:#x}").to_lowercase()).unwrap_or_default();
        let block_time = "";
        let deposit_confirm_height = "";
        let token_id = "";
        let mev_supplier = "";
        let business_hash = "";
        let transaction_type = "";
        let ext_json = "";

        format!(
            "{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}",
            escape_csv(chain),
            escape_csv(&trace_hash),
            escape_csv(status_str),
            escape_csv(service_name),
            escape_csv(business),
            escape_csv(client),
            escape_csv(chainld),
            escape_csv(&process_str),
            escape_csv(process_word_str),
            escape_csv(index),
            escape_csv(inner_index),
            escape_csv(&current_time_str),
            escape_csv(referld),
            escape_csv(contract_address),
            escape_csv(&block_height),
            escape_csv(&block_hash_str),
            escape_csv(block_time),
            escape_csv(deposit_confirm_height),
            escape_csv(token_id),
            escape_csv(mev_supplier),
            escape_csv(business_hash),
            escape_csv(transaction_type),
            escape_csv(ext_json)
        )
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

        let timestamp_duration =
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
        let timestamp_ms = timestamp_duration.as_millis();
        let trace_hash = format!("{tx_hash:#x}");

        let csv_line =
            self.format_csv_line(&trace_hash, process_id, timestamp_ms, None, block_number);

        self.write_to_file(&csv_line);
    }

    /// Log block event at current time point
    pub fn log_block(&self, block_hash: B256, block_number: u64, process_id: TransactionProcessId) {
        if !self.inner.enabled {
            return;
        }

        let timestamp_duration =
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
        let timestamp_ms = timestamp_duration.as_millis();
        let trace_hash = format!("{block_hash:#x}");

        let csv_line = self.format_csv_line(
            &trace_hash,
            process_id,
            timestamp_ms,
            Some(block_hash),
            Some(block_number),
        );

        self.write_to_file(&csv_line);
    }

    /// Log block event with a specific timestamp
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

        let csv_line = self.format_csv_line(
            &trace_hash,
            process_id,
            timestamp_ms,
            Some(block_hash),
            Some(block_number),
        );

        self.write_to_file(&csv_line);
    }
}

/// Global transaction tracer instance (singleton)
static GLOBAL_TRACER: OnceLock<Arc<TransactionTracer>> = OnceLock::new();

/// Initialize the global transaction tracer
///
/// This function should be called once at application startup to initialize
/// the singleton tracer instance. Subsequent calls will be ignored.
pub fn init_global_tracer(enabled: bool, output_path: Option<PathBuf>, node_type: NodeType) {
    let tracer = TransactionTracer::new(enabled, output_path, node_type);
    GLOBAL_TRACER.set(Arc::new(tracer)).ok();
}

/// Get the global transaction tracer
///
/// Returns `None` if the tracer has not been initialized yet.
pub fn get_global_tracer() -> Option<Arc<TransactionTracer>> {
    GLOBAL_TRACER.get().cloned()
}

/// Flush the global transaction tracer
///
/// Forces a flush of the trace file to ensure all buffered data is written.
pub fn flush_global_tracer() {
    if let Some(tracer) = get_global_tracer() {
        tracer.flush();
    }
}

