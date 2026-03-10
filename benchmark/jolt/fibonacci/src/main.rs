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

    #[arg(long, default_value = "20")]
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

    println!(
        "\n=== Jolt Fibonacci Benchmark (n={}) ===\n",
        args.n
    );

    // Use project-local directory to avoid /tmp being blocked by security software
    let target_dir = concat!(env!("CARGO_MANIFEST_DIR"), "/target/jolt-guest");

    if args.execute {
        // Analyze to get trace info and result
        let program_summary = guest::analyze_fib(args.n);
        println!("Result:       fib({}) (see trace output)", args.n);
        println!(
            "Trace Length: {} steps",
            program_summary.trace_len()
        );
    } else {
        // --- compile guest (or use pre-built ELF) ---
        let elf_path = PathBuf::from(target_dir)
            .join("fibonacci-guest-fib")
            .join("riscv64imac-unknown-none-elf")
            .join("release")
            .join("fibonacci-guest");

        let mut program = if elf_path.exists() {
            println!("Using pre-built guest ELF (skipping compilation)...");
            let mut p = jolt_sdk::host::Program::new("fibonacci-guest");
            p.set_func("fib");
            p.elf = Some(elf_path);
            p
        } else {
            println!("Compiling guest program...");
            let compile_start = Instant::now();
            let p = guest::compile_fib(target_dir);
            let compile_time = compile_start.elapsed();
            println!("Compile Time: {:.2}s", compile_time.as_secs_f64());
            p
        };

        // --- preprocessing ---
        println!("Preprocessing...");
        let preprocess_start = Instant::now();
        let shared_preprocessing = guest::preprocess_shared_fib(&mut program);
        let prover_preprocessing = guest::preprocess_prover_fib(shared_preprocessing.clone());
        let verifier_setup = prover_preprocessing.generators.to_verifier_setup();
        let verifier_preprocessing =
            guest::preprocess_verifier_fib(shared_preprocessing, verifier_setup, None);
        let preprocess_time = preprocess_start.elapsed();
        println!("Preprocess:   {:.2}s", preprocess_time.as_secs_f64());

        // --- build prover and verifier ---
        let prove_fib = guest::build_prover_fib(program, prover_preprocessing);
        let verify_fib = guest::build_verifier_fib(verifier_preprocessing);

        // --- prove ---
        let (stop_flag, monitor_handle) = start_peak_monitor();
        let prove_start = Instant::now();

        let (output, proof, io_device) = prove_fib(args.n);

        let prove_time = prove_start.elapsed();
        stop_flag.store(true, Ordering::Relaxed);
        let peak_stats = monitor_handle.join().unwrap();

        // Serialize proof to measure size
        let proof_path = format!("{}/jolt_fib_proof.bin", target_dir);
        let proof_size_kb = serialize_and_print_size("Proof", &proof_path, &proof)
            .map(|_| {
                std::fs::metadata(&proof_path)
                    .map(|m| m.len() as f64 / 1024.0)
                    .unwrap_or(0.0)
            })
            .unwrap_or(0.0);

        // --- verify ---
        let verify_start = Instant::now();
        let is_valid = verify_fib(args.n, output, io_device.panic, proof);
        let verify_time = verify_start.elapsed();

        println!("Result:       fib({}) = {}", args.n, output);
        println!("Valid:        {}", is_valid);
        println!("Prove Time:   {:.2}s", prove_time.as_secs_f64());
        println!("Proof Size:   {:.1} KB", proof_size_kb);
        println!("Verify Time:  {:.3}s", verify_time.as_secs_f64());
        println!("Peak Memory:  {:.1} MB", peak_stats.peak_memory_mb);
        println!("Peak CPU:     {:.1}%", peak_stats.peak_cpu_pct);
    }

    println!();
}
