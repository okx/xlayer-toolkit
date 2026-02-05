//! Multi-threading test script
//!
//! Run: cargo run --release -- --execute

use clap::Parser;
use sp1_sdk::{include_elf, ProverClient, SP1Stdin};

/// The ELF file for the program
pub const PROGRAM_ELF: &[u8] = include_elf!("fibonacci-program");

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    #[arg(long)]
    execute: bool,

    #[arg(long)]
    prove: bool,

    #[arg(long, default_value = "1000")]
    n: u64,
}

fn main() {
    sp1_sdk::utils::setup_logger();
    dotenv::dotenv().ok();

    let args = Args::parse();

    if args.execute == args.prove {
        eprintln!("Error: You must specify either --execute or --prove");
        std::process::exit(1);
    }

    let client = ProverClient::from_env();

    let mut stdin = SP1Stdin::new();
    stdin.write(&args.n);

    println!("═══════════════════════════════════════════════════════════════════");
    println!("  SP1 zkVM Multi-threading Test");
    println!("═══════════════════════════════════════════════════════════════════");
    println!("Test: 4 threads computing 1+2+...+{} in parallel", args.n);
    println!("Expected result: {}", args.n * (args.n + 1) / 2);
    println!();

    if args.execute {
        println!("Executing program...");
        let (mut output, report) = client.execute(PROGRAM_ELF, &stdin).run().unwrap();
        println!("Program execution completed!");
        println!();

        // Read output
        let total: u64 = output.read();
        let is_correct: bool = output.read();

        println!("═══════════════════════════════════════════════════════════════════");
        println!("Execution result:");
        println!("  Computed sum: {}", total);
        println!("  Result correct: {}", is_correct);
        println!("  Instruction count: {}", report.total_instruction_count());
        println!("═══════════════════════════════════════════════════════════════════");

        if is_correct {
            println!();
            println!("✓ Test passed!");
        } else {
            println!();
            println!("✗ Test failed! Result is incorrect.");
            std::process::exit(1);
        }
    } else {
        let (pk, vk) = client.setup(PROGRAM_ELF);

        println!("Generating proof...");
        let proof = client
            .prove(&pk, &stdin)
            .run()
            .expect("failed to generate proof");

        println!("✓ Proof generated successfully!");

        client.verify(&proof, &vk).expect("failed to verify proof");
        println!("✓ Proof verified successfully!");
    }
}
