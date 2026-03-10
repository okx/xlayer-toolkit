use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::time::Instant;

use benchmark_utils::start_peak_monitor;
use clap::Parser;
use jolt_sdk::serialize_and_print_size;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    #[arg(long)]
    execute: bool,

    #[arg(long)]
    prove: bool,

    /// Use inline optimization for SHA-256
    #[arg(long)]
    inline: bool,

    /// Number of SHA-256 iterations
    #[arg(long, default_value = "1000")]
    n: u32,
}

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::filter::EnvFilter::from_default_env())
        .init();

    let args = Args::parse();
    if args.execute == args.prove {
        eprintln!("Error: specify either --execute or --prove");
        std::process::exit(1);
    }

    let mode_label = if args.inline { "inline" } else { "native" };
    println!(
        "\n=== Jolt SHA-256 Benchmark (n={}, mode={}) ===\n",
        args.n, mode_label
    );

    let target_dir = concat!(env!("CARGO_MANIFEST_DIR"), "/target/jolt-guest");
    let input = [0xABu8; 32];

    if args.inline {
        run_inline(&args, target_dir, input);
    } else {
        run_native(&args, target_dir, input);
    }

    println!();
}

fn run_inline(args: &Args, target_dir: &str, input: [u8; 32]) {
    if args.execute {
        let program_summary = guest::analyze_sha2_chain_inline(input, args.n);
        println!("Trace Length: {} steps", program_summary.trace_len());
        return;
    }

    // --- compile guest (or use pre-built ELF) ---
    let elf_path = PathBuf::from(target_dir)
        .join("sha2-guest-sha2_chain_inline")
        .join("riscv64imac-unknown-none-elf")
        .join("release")
        .join("sha2-guest");

    let mut program = if elf_path.exists() {
        println!("Using pre-built guest ELF (inline, skipping compilation)...");
        let mut p = jolt_sdk::host::Program::new("sha2-guest");
        p.set_func("sha2_chain_inline");
        p.elf = Some(elf_path);
        p
    } else {
        println!("Compiling guest program (inline)...");
        let compile_start = Instant::now();
        let p = guest::compile_sha2_chain_inline(target_dir);
        println!("Compile Time: {:.2}s", compile_start.elapsed().as_secs_f64());
        p
    };

    // --- preprocessing ---
    println!("Preprocessing...");
    let preprocess_start = Instant::now();
    let shared_preprocessing = guest::preprocess_shared_sha2_chain_inline(&mut program);
    let prover_preprocessing =
        guest::preprocess_prover_sha2_chain_inline(shared_preprocessing.clone());
    let verifier_setup = prover_preprocessing.generators.to_verifier_setup();
    let verifier_preprocessing =
        guest::preprocess_verifier_sha2_chain_inline(shared_preprocessing, verifier_setup, None);
    let preprocess_time = preprocess_start.elapsed();
    println!("Preprocess:   {:.2}s", preprocess_time.as_secs_f64());

    // --- build prover and verifier ---
    let prove_fn = guest::build_prover_sha2_chain_inline(program, prover_preprocessing);
    let verify_fn = guest::build_verifier_sha2_chain_inline(verifier_preprocessing);

    // --- prove ---
    let (stop_flag, monitor_handle) = start_peak_monitor();
    let prove_start = Instant::now();

    let (output, proof, io_device) = prove_fn(input, args.n);

    let prove_time = prove_start.elapsed();
    stop_flag.store(true, Ordering::Relaxed);
    let peak_stats = monitor_handle.join().unwrap();

    // Serialize proof to measure size
    let proof_path = format!("{}/jolt_sha2_inline_proof.bin", target_dir);
    let proof_size_kb = serialize_and_print_size("Proof", &proof_path, &proof)
        .map(|_| {
            std::fs::metadata(&proof_path)
                .map(|m| m.len() as f64 / 1024.0)
                .unwrap_or(0.0)
        })
        .unwrap_or(0.0);

    // --- verify ---
    let verify_start = Instant::now();
    let is_valid = verify_fn(input, args.n, output, io_device.panic, proof);
    let verify_time = verify_start.elapsed();

    println!("Result:       {}", hex::encode(output));
    println!("Valid:        {}", is_valid);
    println!("Prove Time:   {:.2}s", prove_time.as_secs_f64());
    println!("Proof Size:   {:.1} KB", proof_size_kb);
    println!("Verify Time:  {:.3}s", verify_time.as_secs_f64());
    println!("Peak Memory:  {:.1} MB", peak_stats.peak_memory_mb);
    println!("Peak CPU:     {:.1}%", peak_stats.peak_cpu_pct);
}

fn run_native(args: &Args, target_dir: &str, input: [u8; 32]) {
    if args.execute {
        let program_summary = guest::analyze_sha2_chain_native(input, args.n);
        println!("Trace Length: {} steps", program_summary.trace_len());
        return;
    }

    // --- compile guest (or use pre-built ELF) ---
    let elf_path = PathBuf::from(target_dir)
        .join("sha2-guest-sha2_chain_native")
        .join("riscv64imac-unknown-none-elf")
        .join("release")
        .join("sha2-guest");

    let mut program = if elf_path.exists() {
        println!("Using pre-built guest ELF (native, skipping compilation)...");
        let mut p = jolt_sdk::host::Program::new("sha2-guest");
        p.set_func("sha2_chain_native");
        p.elf = Some(elf_path);
        p
    } else {
        println!("Compiling guest program (native)...");
        let compile_start = Instant::now();
        let p = guest::compile_sha2_chain_native(target_dir);
        println!("Compile Time: {:.2}s", compile_start.elapsed().as_secs_f64());
        p
    };

    // --- preprocessing ---
    println!("Preprocessing...");
    let preprocess_start = Instant::now();
    let shared_preprocessing = guest::preprocess_shared_sha2_chain_native(&mut program);
    let prover_preprocessing =
        guest::preprocess_prover_sha2_chain_native(shared_preprocessing.clone());
    let verifier_setup = prover_preprocessing.generators.to_verifier_setup();
    let verifier_preprocessing =
        guest::preprocess_verifier_sha2_chain_native(shared_preprocessing, verifier_setup, None);
    let preprocess_time = preprocess_start.elapsed();
    println!("Preprocess:   {:.2}s", preprocess_time.as_secs_f64());

    // --- build prover and verifier ---
    let prove_fn = guest::build_prover_sha2_chain_native(program, prover_preprocessing);
    let verify_fn = guest::build_verifier_sha2_chain_native(verifier_preprocessing);

    // --- prove ---
    let (stop_flag, monitor_handle) = start_peak_monitor();
    let prove_start = Instant::now();

    let (output, proof, io_device) = prove_fn(input, args.n);

    let prove_time = prove_start.elapsed();
    stop_flag.store(true, Ordering::Relaxed);
    let peak_stats = monitor_handle.join().unwrap();

    // Serialize proof to measure size
    let proof_path = format!("{}/jolt_sha2_native_proof.bin", target_dir);
    let proof_size_kb = serialize_and_print_size("Proof", &proof_path, &proof)
        .map(|_| {
            std::fs::metadata(&proof_path)
                .map(|m| m.len() as f64 / 1024.0)
                .unwrap_or(0.0)
        })
        .unwrap_or(0.0);

    // --- verify ---
    let verify_start = Instant::now();
    let is_valid = verify_fn(input, args.n, output, io_device.panic, proof);
    let verify_time = verify_start.elapsed();

    println!("Result:       {}", hex::encode(output));
    println!("Valid:        {}", is_valid);
    println!("Prove Time:   {:.2}s", prove_time.as_secs_f64());
    println!("Proof Size:   {:.1} KB", proof_size_kb);
    println!("Verify Time:  {:.3}s", verify_time.as_secs_f64());
    println!("Peak Memory:  {:.1} MB", peak_stats.peak_memory_mb);
    println!("Peak CPU:     {:.1}%", peak_stats.peak_cpu_pct);
}
