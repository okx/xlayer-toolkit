use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

use alloy_sol_types::SolType;
use clap::Parser;
use fibonacci_lib::PublicValuesStruct;
use sp1_sdk::{
    blocking::{ProveRequest, Prover, ProverClient},
    include_elf, Elf, ProvingKey, SP1Stdin,
};

const FIBONACCI_ELF: Elf = include_elf!("fibonacci-program");

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

struct PeakStats {
    peak_memory_mb: f64,
    peak_cpu_pct: f64,
}

/// Read VmRSS (current resident set) from /proc/self/status, in KB.
fn read_vm_rss_kb() -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .unwrap_or_default()
        .lines()
        .find(|l| l.starts_with("VmRSS:"))
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}

/// Read utime+stime in jiffies from /proc/self/stat.
fn read_cpu_ticks() -> u64 {
    let stat = std::fs::read_to_string("/proc/self/stat").unwrap_or_default();
    if let Some(pos) = stat.rfind(')') {
        let rest: Vec<&str> = stat[pos + 1..].split_whitespace().collect();
        let utime: u64 = rest.get(11).and_then(|s| s.parse().ok()).unwrap_or(0);
        let stime: u64 = rest.get(12).and_then(|s| s.parse().ok()).unwrap_or(0);
        utime + stime
    } else {
        0
    }
}

/// Spawn a background thread that samples peak RSS and peak CPU every 100 ms.
fn start_peak_monitor() -> (Arc<AtomicBool>, std::thread::JoinHandle<PeakStats>) {
    let stop = Arc::new(AtomicBool::new(false));
    let stop_clone = Arc::clone(&stop);

    let handle = std::thread::spawn(move || {
        let mut peak_mem_mb = 0f64;
        let mut peak_cpu_pct = 0f64;
        let ncpus = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1) as f64;
        const TICKS_PER_SEC: f64 = 100.0;

        let mut prev_ticks = read_cpu_ticks();
        let mut prev_time = Instant::now();

        while !stop_clone.load(Ordering::Relaxed) {
            std::thread::sleep(std::time::Duration::from_millis(100));

            let rss_mb = read_vm_rss_kb() as f64 / 1024.0;
            if rss_mb > peak_mem_mb {
                peak_mem_mb = rss_mb;
            }

            let curr_ticks = read_cpu_ticks();
            let curr_time = Instant::now();
            let elapsed = curr_time.duration_since(prev_time).as_secs_f64();
            let cpu_secs = curr_ticks.saturating_sub(prev_ticks) as f64 / TICKS_PER_SEC;
            let pct = if elapsed > 0.0 {
                (cpu_secs / elapsed / ncpus * 100.0).min(100.0 * ncpus)
            } else {
                0.0
            };
            if pct > peak_cpu_pct {
                peak_cpu_pct = pct;
            }

            prev_ticks = curr_ticks;
            prev_time = curr_time;
        }

        PeakStats {
            peak_memory_mb: peak_mem_mb,
            peak_cpu_pct,
        }
    });

    (stop, handle)
}

fn main() {
    sp1_sdk::utils::setup_logger();
    dotenv::dotenv().ok();

    let args = Args::parse();
    if args.execute == args.prove {
        eprintln!("Error: specify either --execute or --prove");
        std::process::exit(1);
    }

    let client = ProverClient::from_env();

    println!("\n=== SP1 Fibonacci Benchmark (Hypercube, n={}) ===\n", args.n);

    if args.execute {
        let mut stdin = SP1Stdin::new();
        stdin.write(&args.n);
        let (output, report) = client.execute(FIBONACCI_ELF, stdin).run().unwrap();
        let decoded = PublicValuesStruct::abi_decode(output.as_slice()).unwrap();
        let PublicValuesStruct { n, a, b } = decoded;
        println!("Result:       fib({}) = {}, fib({}) = {}", n - 1, a, n, b);
        println!("Cycle Count:  {} cycles", report.total_instruction_count());
    } else {
        // --- execute first to get cycle count ---
        let mut stdin_exec = SP1Stdin::new();
        stdin_exec.write(&args.n);
        let (_, report) = client.execute(FIBONACCI_ELF, stdin_exec).run().unwrap();
        let cycle_count = report.total_instruction_count();

        // --- setup proving key (derived from the ELF embedded at build time) ---
        let pk = client.setup(FIBONACCI_ELF).expect("failed to setup elf");

        // --- prove with Hypercube (compressed mode) ---
        let mut stdin_prove = SP1Stdin::new();
        stdin_prove.write(&args.n);

        let (stop_flag, monitor_handle) = start_peak_monitor();
        let prove_start = Instant::now();
        let proof = client
            .prove(&pk, stdin_prove)
            .compressed()
            .run()
            .expect("failed to generate proof");
        let prove_time = prove_start.elapsed();

        stop_flag.store(true, Ordering::Relaxed);
        let peak_stats = monitor_handle.join().unwrap();

        let proof_bytes = serde_json::to_vec(&proof).expect("failed to serialize proof");
        let proof_size_kb = proof_bytes.len() as f64 / 1024.0;

        let verify_start = Instant::now();
        client
            .verify(&proof, pk.verifying_key(), None)
            .expect("failed to verify proof");
        let verify_time = verify_start.elapsed();

        println!("Cycle Count:  {} cycles", cycle_count);
        println!("Prove Time:   {:.2}s", prove_time.as_secs_f64());
        println!("Proof Size:   {:.1} KB", proof_size_kb);
        println!("Verify Time:  {:.3}s", verify_time.as_secs_f64());
        println!("Peak Memory:  {:.1} MB", peak_stats.peak_memory_mb);
        println!("Peak CPU:     {:.1}%", peak_stats.peak_cpu_pct);
    }

    println!();
}
