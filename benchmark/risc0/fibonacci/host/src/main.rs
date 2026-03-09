use std::sync::atomic::Ordering;
use std::time::Instant;

use benchmark_utils::start_peak_monitor;
use clap::{Parser, ValueEnum};
use fibonacci_core::fibonacci;
use fibonacci_methods::FIBONACCI_GUEST_ELF;
use risc0_zkvm::{default_executor, default_prover, ExecutorEnv, ProverOpts};

#[derive(ValueEnum, Clone, Debug)]
enum ProofMode {
    Composite,
    Succinct,
    Groth16,
}

impl std::fmt::Display for ProofMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ProofMode::Composite => write!(f, "Composite"),
            ProofMode::Succinct => write!(f, "Succinct"),
            ProofMode::Groth16 => write!(f, "Groth16"),
        }
    }
}

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    #[arg(long)]
    execute: bool,

    #[arg(long)]
    prove: bool,

    #[arg(long, default_value = "20")]
    n: u32,

    #[arg(long, value_enum, default_value = "composite")]
    mode: ProofMode,
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
        "\n=== RISC Zero Fibonacci Benchmark ({}, n={}) ===\n",
        args.mode, args.n
    );

    if args.execute {
        let env = ExecutorEnv::builder()
            .write(&args.n)
            .unwrap()
            .build()
            .unwrap();
        let session = default_executor().execute(env, FIBONACCI_GUEST_ELF).unwrap();
        let (n, a, b): (u32, u32, u32) = session.journal.decode().unwrap();

        // Verify against host computation
        let (expected_a, expected_b) = fibonacci(args.n);
        assert_eq!(a, expected_a);
        assert_eq!(b, expected_b);

        println!(
            "Result:       fib({}) = {}, fib({}) = {}",
            n - 1, a, n, b
        );
        println!("Cycle Count:  {} cycles", session.cycles());
    } else {
        // --- execute first to get cycle count ---
        let env_exec = ExecutorEnv::builder()
            .write(&args.n)
            .unwrap()
            .build()
            .unwrap();
        let session = default_executor()
            .execute(env_exec, FIBONACCI_GUEST_ELF)
            .unwrap();
        let cycle_count = session.cycles();

        // --- prove with selected mode ---
        let env_prove = ExecutorEnv::builder()
            .write(&args.n)
            .unwrap()
            .build()
            .unwrap();

        let opts = match args.mode {
            ProofMode::Composite => ProverOpts::default(),
            ProofMode::Succinct => ProverOpts::succinct(),
            ProofMode::Groth16 => ProverOpts::groth16(),
        };

        let (stop_flag, monitor_handle) = start_peak_monitor();
        let prove_start = Instant::now();

        let prove_info = default_prover()
            .prove_with_opts(env_prove, FIBONACCI_GUEST_ELF, &opts)
            .expect("failed to generate proof");
        let receipt = prove_info.receipt;

        let prove_time = prove_start.elapsed();

        stop_flag.store(true, Ordering::Relaxed);
        let peak_stats = monitor_handle.join().unwrap();

        let proof_size = bincode::serialize(&receipt)
            .expect("failed to serialize receipt")
            .len();

        // --- verify ---
        let verify_start = Instant::now();
        receipt
            .verify(fibonacci_methods::FIBONACCI_GUEST_ID)
            .expect("failed to verify receipt");
        let verify_time = verify_start.elapsed();

        // --- decode output ---
        let (n, a, b): (u32, u32, u32) = receipt.journal.decode().unwrap();

        println!(
            "Result:       fib({}) = {}, fib({}) = {}",
            n - 1, a, n, b
        );
        println!("Proof Mode:   {}", args.mode);
        println!("Cycle Count:  {} cycles", cycle_count);
        println!("Prove Time:   {:.2}s", prove_time.as_secs_f64());
        println!("Proof Size:   {} bytes", proof_size);
        println!("Verify Time:  {:.3}s", verify_time.as_secs_f64());
        println!("Peak Memory:  {:.1} MB", peak_stats.peak_memory_mb);
        println!("Peak CPU:     {:.1}%", peak_stats.peak_cpu_pct);
    }

    println!();
}
