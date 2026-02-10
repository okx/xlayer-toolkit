//! Multi-threaded test host program
//!
//! This is the host-side program that:
//! 1. Compiles the guest program
//! 2. Proves the execution
//! 3. Verifies the proof

use std::time::Instant;
use tracing::info;

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    info!("Multi-threaded Test: Jolt zkVM + ZeroOS");
    info!("========================================\n");

    // Input: compute 1+2+...+100
    let n: u64 = 100;
    info!("Input: n = {}", n);
    info!("Expected sum: {}\n", n * (n + 1) / 2);

    // Compile the guest program
    let target_dir = "/tmp/jolt-guest-targets";
    info!("Compiling guest program...");
    let start = Instant::now();
    let mut program = guest::compile_compute_sum(target_dir);
    info!("Compile time: {:?}", start.elapsed());

    info!("\nPreprocessing...");
    let start = Instant::now();
    let prover_preprocessing = guest::preprocess_prover_compute_sum(&mut program);
    let verifier_preprocessing =
        guest::verifier_preprocessing_from_prover_compute_sum(&prover_preprocessing);
    info!("Preprocessing time: {:?}", start.elapsed());

    let prove_compute_sum = guest::build_prover_compute_sum(program, prover_preprocessing);
    let verify_compute_sum = guest::build_verifier_compute_sum(verifier_preprocessing);

    // Analyze trace length
    info!("\nAnalyzing trace...");
    let program_summary = guest::analyze_compute_sum(n);
    let trace_length = program_summary.trace.len();
    info!("Trace length: {}", trace_length);
    drop(program_summary);

    // Prove
    info!("\nProving multi-threaded computation...");
    let start = Instant::now();
    let (output, proof, program_io) = prove_compute_sum(n);
    let prove_time = start.elapsed();
    info!("Prove time: {:?}", prove_time);

    // Check output
    info!("\nComputation Result:");
    info!("  Input n: {}", output.n);
    info!("  Computed sum: {}", output.total);
    info!("  Expected sum: {}", output.expected);
    info!("  Correct: {}", output.is_correct);
    info!("  Thread completion order: {:?}", output.completion_order);

    // Verify
    info!("\nVerifying proof...");
    let start = Instant::now();
    let is_valid = verify_compute_sum(n, output.clone(), program_io.panic, proof);
    let verify_time = start.elapsed();
    info!("Verify time: {:?}", verify_time);
    info!("Proof valid: {}", is_valid);

    if is_valid && output.is_correct {
        info!("\n✅ Multi-threaded zkVM computation successful!");
    } else {
        info!("\n❌ Verification failed!");
    }
}
