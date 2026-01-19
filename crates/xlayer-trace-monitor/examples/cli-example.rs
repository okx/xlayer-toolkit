//! Example: Using xlayer-trace-monitor with command line arguments
//!
//! This example shows how to integrate the trace monitor with CLI argument parsing.
//! 
//! **Note**: This example requires the `clap` crate. Add it to your Cargo.toml:
//! ```toml
//! [dev-dependencies]
//! clap = { version = "4.0", features = ["derive"] }
//! ```
//!
//! Run with:
//! ```bash
//! cargo run --example cli-example -- --tx-trace.enable --tx-trace.output-path=/tmp/trace.log
//! ```

//! Example: Using xlayer-trace-monitor with command line arguments
//!
//! This example shows how to integrate the trace monitor with CLI argument parsing.
//! 
//! **Note**: This example requires the `clap` crate. Add it to your Cargo.toml:
//! ```toml
//! [dev-dependencies]
//! clap = { version = "4.0", features = ["derive"] }
//! ```
//!
//! Since this crate doesn't include clap, this example won't compile by default.
//! It's provided as a reference for how to use the crate with CLI arguments.

use xlayer_trace_monitor::{init_global_tracer, get_global_tracer, TransactionProcessId};
use alloy_primitives::B256;
use std::path::PathBuf;

fn main() {
    // In a real application, you would parse these from command line arguments
    // using clap or another CLI library:
    //
    // #[derive(Parser)]
    // struct Args {
    //     #[arg(long = "tx-trace.enable")]
    //     tx_trace_enable: bool,
    //     #[arg(long = "tx-trace.output-path")]
    //     tx_trace_output_path: Option<PathBuf>,
    // }
    // let args = Args::parse();
    
    // For this example, we'll use hardcoded values:
    let enabled = true;
    let output_path = Some(PathBuf::from("/tmp/trace.log"));
    
    // Initialize the global tracer with parsed arguments
    init_global_tracer(enabled, output_path.clone());
    
    println!("Tracer initialized:");
    println!("  Enabled: {}", enabled);
    println!("  Output path: {:?}", output_path);
    
    // Example: Log some transaction events
    if let Some(tracer) = get_global_tracer() {
        if tracer.is_enabled() {
            println!("\nLogging example transaction events...");
            
            // Example transaction hash
            let tx_hash = B256::from([0x12; 32]);
            
            // Log a transaction event
            tracer.log_transaction(
                tx_hash,
                TransactionProcessId::SeqReceiveTxEnd,
                Some(12345),
            );
            
            println!("Transaction event logged!");
            
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

