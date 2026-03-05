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

const SHA2_ELF: Elf = include_elf!("sha2-program");

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

    println!(
        "\n=== SP1 SHA-{} Benchmark ({}, input={}B) ===\n",
        args.n, args.mode, args.input_size
    );

    if args.execute {
        let mut stdin = SP1Stdin::new();
        stdin.write(&args.n);
        stdin.write(&input_data);
        let (output, report) = client.execute(SHA2_ELF, stdin).run().unwrap();
        let decoded = PublicValuesStruct::abi_decode(output.as_slice()).unwrap();
        println!("Variant:      SHA-{}", decoded.variant);
        println!("Digest:       0x{}", hex::encode(decoded.digest));
        println!("Cycle Count:  {} cycles", report.total_instruction_count());
    } else {
        // --- execute first to get cycle count ---
        let mut stdin_exec = SP1Stdin::new();
        stdin_exec.write(&args.n);
        stdin_exec.write(&input_data);
        let (_, report) = client.execute(SHA2_ELF, stdin_exec).run().unwrap();
        let cycle_count = report.total_instruction_count();

        // --- setup proving key ---
        let pk = client.setup(SHA2_ELF).expect("failed to setup elf");

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

        // --- verify (skip for Core which is not on-chain verifiable) ---
        let verify_time = match args.mode {
            ProofMode::Core => None,
            _ => {
                let vk = pk.verifying_key();
                let start = Instant::now();
                client
                    .verify(&proof, vk, None)
                    .expect("failed to verify proof");
                Some(start.elapsed())
            }
        };

        println!("Proof Mode:   {}", args.mode);
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
}
