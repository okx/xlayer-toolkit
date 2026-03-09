use std::sync::atomic::Ordering;
use std::time::Instant;

use benchmark_utils::start_peak_monitor;
use clap::{Parser, ValueEnum};
use risc0_zkvm::{default_executor, default_prover, ExecutorEnv, ProverOpts};
use sha2_core::sha2_hash;
use sha2_methods::{
    SHA2_GUEST_ELF, SHA2_GUEST_ID, SHA2_GUEST_PRECOMPILE_ELF, SHA2_GUEST_PRECOMPILE_ID,
};

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

    /// SHA-2 variant: 224, 256, 384, or 512
    #[arg(long, default_value = "256")]
    n: u32,

    #[arg(long, value_enum, default_value = "composite")]
    mode: ProofMode,

    /// Size of input data to hash (bytes)
    #[arg(long, default_value = "32")]
    input_size: usize,

    /// Use RISC Zero precompile for SHA-256 (accelerated circuit)
    #[arg(long, default_value = "false")]
    precompile: bool,
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

    if !matches!(args.n, 224 | 256 | 384 | 512) {
        eprintln!("Error: --n must be 224, 256, 384, or 512");
        std::process::exit(1);
    }

    let (elf, image_id) = if args.precompile {
        (SHA2_GUEST_PRECOMPILE_ELF, SHA2_GUEST_PRECOMPILE_ID)
    } else {
        (SHA2_GUEST_ELF, SHA2_GUEST_ID)
    };

    let input_data: Vec<u8> = vec![0xAB; args.input_size];

    println!(
        "\n=== RISC Zero SHA-{} Benchmark ({}, input={}B, precompile={}) ===\n",
        args.n, args.mode, args.input_size, args.precompile
    );

    if args.execute {
        let env = ExecutorEnv::builder()
            .write(&args.n)
            .unwrap()
            .write(&input_data)
            .unwrap()
            .build()
            .unwrap();
        let session = default_executor().execute(env, elf).unwrap();
        let (variant, digest): (u32, [u8; 32]) = session.journal.decode().unwrap();

        // Verify against host computation
        let expected = sha2_hash(args.n, &input_data);
        assert_eq!(digest, expected, "guest digest mismatch");

        println!("SHA Variant:  SHA-{}", variant);
        println!("Digest:       0x{}", hex::encode(digest));
        println!("Input Size:   {} bytes", args.input_size);
        println!("Precompile:   {}", args.precompile);
        println!("Cycle Count:  {} cycles", session.cycles());
    } else {
        // --- execute first to get cycle count ---
        let env_exec = ExecutorEnv::builder()
            .write(&args.n)
            .unwrap()
            .write(&input_data)
            .unwrap()
            .build()
            .unwrap();
        let session = default_executor().execute(env_exec, elf).unwrap();
        let cycle_count = session.cycles();

        // --- prove with selected mode ---
        let env_prove = ExecutorEnv::builder()
            .write(&args.n)
            .unwrap()
            .write(&input_data)
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
            .prove_with_opts(env_prove, elf, &opts)
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
        receipt.verify(image_id).expect("failed to verify receipt");
        let verify_time = verify_start.elapsed();

        // --- decode output ---
        let (variant, digest): (u32, [u8; 32]) = receipt.journal.decode().unwrap();

        println!("SHA Variant:  SHA-{}", variant);
        println!("Digest:       0x{}", hex::encode(digest));
        println!("Input Size:   {} bytes", args.input_size);
        println!("Precompile:   {}", args.precompile);
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
