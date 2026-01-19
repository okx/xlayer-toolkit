//! Simple example: Using xlayer-trace-monitor
//!
//! This example shows basic usage without any CLI framework dependencies.
//!
//! Run with:
//! ```bash
//! cargo run --example simple-example
//! ```

use xlayer_trace_monitor::{
    init_global_tracer, get_global_tracer, TransactionProcessId,
};
use alloy_primitives::B256;
use std::path::PathBuf;

fn main() {
    // Initialize the tracer
    // In a real application, you would parse these values from command line arguments
    // using your preferred CLI library (clap, structopt, etc.)
    init_global_tracer(
        true,  // enabled - from --tx-trace.enable flag
        Some(PathBuf::from("/tmp/trace.log")),  // output_path - from --tx-trace.output-path flag
    );

    println!("Tracer initialized!");

    // Example: Log some transaction events
    if let Some(tracer) = get_global_tracer() {
        if tracer.is_enabled() {
            println!("Logging example transaction events...");

            // Example transaction hash
            let tx_hash = B256::from([0x12; 32]);

            // Log a transaction event
            tracer.log_transaction(
                tx_hash,
                TransactionProcessId::SeqReceiveTxEnd,
                Some(12345),
            );

            println!("Transaction event logged to file!");

            // Flush to ensure data is written
            if let Err(e) = tracer.flush() {
                eprintln!("Failed to flush: {}", e);
            }
        } else {
            println!("Tracing is disabled");
        }
    } else {
        println!("Tracer not initialized");
    }
}

