use std::sync::atomic::Ordering;
use std::time::Instant;

use alloy_sol_types::SolType;
use benchmark_utils::start_peak_monitor;
use clap::{Parser, ValueEnum};
use sha2_lib::PublicValuesStruct;
use sp1_sdk::{
    blocking::{ProveRequest, Prover, ProverClient},
    include_elf, Elf, ProvingKey, SP1Proof, SP1Stdin,
};

const SHA2_ELF_VANILLA: Elf = include_elf!("sha2-program-vanilla");
const SHA2_ELF_PRECOMPILE: Elf = include_elf!("sha2-program-precompile");

#[derive(ValueEnum, Clone, Debug)]
enum ProofMode {
    Core,
    Compressed,
    Groth16,
}

impl std::fmt::Display for ProofMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ProofMode::Core => write!(f, "Core"),
            ProofMode::Compressed => write!(f, "Compressed"),
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

    #[arg(long, value_enum, default_value = "core")]
    mode: ProofMode,

    /// Size of input data to hash (bytes)
    #[arg(long, default_value = "32")]
    input_size: usize,

    /// Use SP1 precompile for SHA-256 (accelerated syscall)
    #[arg(long, default_value = "false")]
    precompile: bool,
}

fn main() {
    sp1_sdk::utils::setup_logger();
    dotenv::dotenv().ok();

    let args = Args::parse();
    if args.execute == args.prove {
        eprintln!("Error: specify either --execute or --prove");
        std::process::exit(1);
    }

    if !matches!(args.n, 224 | 256 | 384 | 512) {
        eprintln!("Error: --n must be 224, 256, 384, or 512");
        std::process::exit(1);
    }

    let client = ProverClient::from_env();
    let input_data: Vec<u8> = vec![0xAB; args.input_size];
    let elf = if args.precompile {
        SHA2_ELF_PRECOMPILE
    } else {
        SHA2_ELF_VANILLA
    };

    println!(
        "\n=== SP1 SHA-{} Benchmark ({}, input={}B, precompile={}) ===\n",
        args.n, args.mode, args.input_size, args.precompile
    );

    if args.execute {
        let mut stdin = SP1Stdin::new();
        stdin.write(&args.n);
        stdin.write(&input_data);
        let (output, report) = client.execute(elf, stdin).run().unwrap();
        let decoded = PublicValuesStruct::abi_decode(output.as_slice()).unwrap();
        println!("Variant:      SHA-{}", decoded.variant);
        println!("Digest:       0x{}", hex::encode(decoded.digest));
        println!("Cycle Count:  {} cycles", report.total_instruction_count());
    } else {
        // --- execute first to get cycle count ---
        let mut stdin_exec = SP1Stdin::new();
        stdin_exec.write(&args.n);
        stdin_exec.write(&input_data);
        let (_, report) = client.execute(elf.clone(), stdin_exec).run().unwrap();
        let cycle_count = report.total_instruction_count();

        // --- setup proving key ---
        let pk = client.setup(elf).expect("failed to setup elf");

        // --- prove with selected mode ---
        let mut stdin_prove = SP1Stdin::new();
        stdin_prove.write(&args.n);
        stdin_prove.write(&input_data);

        let (stop_flag, monitor_handle) = start_peak_monitor();
        let prove_start = Instant::now();

        let proof = match args.mode {
            ProofMode::Core => client.prove(&pk, stdin_prove).run(),
            ProofMode::Compressed => client.prove(&pk, stdin_prove).compressed().run(),
            ProofMode::Groth16 => client.prove(&pk, stdin_prove).groth16().run(),
        }
        .expect("failed to generate proof");

        let prove_time = prove_start.elapsed();

        stop_flag.store(true, Ordering::Relaxed);
        let peak_stats = monitor_handle.join().unwrap();

        let total_size = postcard::to_allocvec(&proof)
            .expect("failed to serialize proof")
            .len();
        let raw_proof_bytes = match &proof.proof {
            SP1Proof::Groth16(p) => p.raw_proof.len() / 2, // hex string → bytes
            _ => postcard::to_allocvec(&proof.proof).unwrap().len(),
        };

        // --- verify (skip for Core; tolerate mock prover failures) ---
        let is_mock = std::env::var("SP1_PROVER").unwrap_or_default() == "mock";
        let verify_time = match args.mode {
            ProofMode::Core => None,
            _ => {
                let vk = pk.verifying_key();
                let start = Instant::now();
                match client.verify(&proof, vk, None) {
                    Ok(_) => Some(start.elapsed()),
                    Err(e) if is_mock => {
                        println!("Verify:       skipped (mock prover: {})", e);
                        None
                    }
                    Err(e) => panic!("failed to verify proof: {}", e),
                }
            }
        };

        println!("Proof Mode:   {}", args.mode);
        println!("Precompile:   {}", args.precompile);
        println!("SHA Variant:  SHA-{}", args.n);
        println!("Input Size:   {} bytes", args.input_size);
        println!("Cycle Count:  {} cycles", cycle_count);
        println!("Prove Time:   {:.2}s", prove_time.as_secs_f64());
        println!("Proof Size:   {} bytes (raw proof) / {} bytes (total)", raw_proof_bytes, total_size);
        match verify_time {
            Some(t) => println!("Verify Time:  {:.3}s", t.as_secs_f64()),
            None => println!("Verify:       skipped (Core, not on-chain verifiable)"),
        }
        println!("Peak Memory:  {:.1} MB", peak_stats.peak_memory_mb);
        println!("Peak CPU:     {:.1}%", peak_stats.peak_cpu_pct);
    }

    println!();

    // Exit immediately to avoid sp1-cuda Drop panic
    std::process::exit(0);
}
