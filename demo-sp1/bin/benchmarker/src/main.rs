//! ZK Bisection Benchmarker
//!
//! Sends transactions to the L2 node at a configurable TPS rate.
//! 
//! Flow:
//! 1. Generate 10,000 test accounts (deterministic)
//! 2. Initialize accounts: Treasury → each account (1 ETH)
//! 3. Run benchmark: accounts randomly transfer to each other

use rand::{Rng, SeedableRng};
use rand::rngs::StdRng;
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::time::{interval, sleep};
use tracing::{info, warn, error, Level};
use tracing_subscriber::FmtSubscriber;
use tiny_keccak::{Hasher, Keccak};

/// Number of test accounts
const ACCOUNT_COUNT: usize = 10_000;

/// Initial balance per account: 1 ETH = 10^18 wei
const INIT_BALANCE: u64 = 1_000_000_000_000_000_000;

/// Transfer amount: 1wei (small to allow many transfers)
const TRANSFER_AMOUNT: u64 = 1;

/// Treasury address (matches Node)
const TREASURY_ADDRESS: &str = "0x0000000000000000000000000000000000000000000000000000000000000001";

/// Benchmarker configuration
struct Config {
    node_rpc: String,
    target_tps: u64,
}

impl Config {
    fn from_env() -> Self {
        Self {
            node_rpc: std::env::var("NODE_RPC").unwrap_or_else(|_| "http://node:8546".to_string()),
            target_tps: std::env::var("BENCHMARK_TPS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(100),
        }
    }
    
    fn batch_size(&self) -> usize {
        (self.target_tps as usize / 20).max(10).min(100)
    }
    
    fn report_interval(&self) -> u64 {
        10
    }
}

/// Test account with address and nonce tracking
struct TestAccount {
    address: String,
    nonce: u64,
}

/// Statistics
#[derive(Default)]
struct Stats {
    sent: AtomicU64,
    success: AtomicU64,
    failed: AtomicU64,
    total_latency_ms: AtomicU64,
}

impl Stats {
    fn record_success(&self, count: u64, latency_ms: u64) {
        self.sent.fetch_add(count, Ordering::Relaxed);
        self.success.fetch_add(count, Ordering::Relaxed);
        self.total_latency_ms.fetch_add(latency_ms * count, Ordering::Relaxed);
    }

    fn record_failure(&self, count: u64) {
        self.sent.fetch_add(count, Ordering::Relaxed);
        self.failed.fetch_add(count, Ordering::Relaxed);
    }

    fn snapshot(&self) -> (u64, u64, u64, u64) {
        (
            self.sent.load(Ordering::Relaxed),
            self.success.load(Ordering::Relaxed),
            self.failed.load(Ordering::Relaxed),
            self.total_latency_ms.load(Ordering::Relaxed),
        )
    }
}

/// Transaction input
#[derive(Serialize)]
struct TxInput {
    tx_type: String,
    from: String,
    to: String,
    amount: u64,
    nonce: u64,
}

/// RPC request
#[derive(Serialize)]
struct RpcRequest {
    jsonrpc: &'static str,
    method: &'static str,
    params: serde_json::Value,
    id: u64,
}

/// RPC response
#[derive(Deserialize)]
struct RpcResponse {
    result: serde_json::Value,
}

#[tokio::main]
async fn main() {
    let subscriber = FmtSubscriber::builder()
        .with_max_level(Level::INFO)
        .finish();
    tracing::subscriber::set_global_default(subscriber).expect("setting default subscriber failed");

    let config = Config::from_env();
    print_banner(&config);

    // Wait for node
    wait_for_node(&config).await;

    // Generate test accounts
    info!("Generating {} test accounts...", ACCOUNT_COUNT);
    let mut accounts = generate_accounts(ACCOUNT_COUNT);
    info!("  ✓ Generated {} accounts", accounts.len());

    // Initialize accounts with balance from treasury
    info!("Initializing accounts with 1 ETH each...");
    if let Err(e) = initialize_accounts(&config, &mut accounts).await {
        error!("Failed to initialize accounts: {}", e);
        return;
    }
    info!("  ✓ All accounts initialized");

    // Run benchmark
    let stats = Arc::new(Stats::default());
    let start_time = Instant::now();

    let reporter_stats = stats.clone();
    let reporter_start = start_time;
    let report_interval = config.report_interval();
    tokio::spawn(async move {
        reporter_loop(reporter_stats, report_interval, reporter_start).await;
    });

    run_benchmark(&config, &mut accounts, stats.clone()).await;

    print_final_report(&stats, start_time.elapsed());
}

fn print_banner(config: &Config) {
    info!("╔═══════════════════════════════════════════════╗");
    info!("║         xlayer-dex Benchmarker                ║");
    info!("╚═══════════════════════════════════════════════╝");
    info!("");
    info!("Configuration:");
    info!("  Node RPC:     {}", config.node_rpc);
    info!("  Target TPS:   {}", config.target_tps);
    info!("  Batch size:   {} (auto)", config.batch_size());
    info!("  Accounts:     {}", ACCOUNT_COUNT);
    info!("");
}

/// Generate deterministic test accounts
fn generate_accounts(count: usize) -> Vec<TestAccount> {
    (0..count)
        .map(|i| {
            let mut hasher = Keccak::v256();
            hasher.update(b"benchmark_account_");
            hasher.update(&(i as u64).to_be_bytes());
            let mut hash = [0u8; 32];
            hasher.finalize(&mut hash);
            
            TestAccount {
                address: format!("0x{}", hex::encode(hash)),
                nonce: 0,
            }
        })
        .collect()
}

async fn wait_for_node(config: &Config) {
    info!("Waiting for node to be ready...");
    let client = reqwest::Client::new();
    
    loop {
        match client
            .post(&config.node_rpc)
            .json(&RpcRequest {
                jsonrpc: "2.0",
                method: "x2_blockNumber",
                params: serde_json::json!([]),
                id: 1,
            })
            .send()
            .await
        {
            Ok(resp) if resp.status().is_success() => {
                info!("  ✓ Node is ready");
                break;
            }
            _ => {
                sleep(Duration::from_secs(2)).await;
            }
        }
    }
}

/// Initialize all accounts with balance from treasury
async fn initialize_accounts(config: &Config, accounts: &mut [TestAccount]) -> Result<(), String> {
    let client = reqwest::Client::new();
    let batch_size = 100;
    let mut treasury_nonce: u64 = 0;
    
    info!("  Sending {} init transactions in {} batches...", 
          accounts.len(), (accounts.len() + batch_size - 1) / batch_size);
    
    for (batch_idx, chunk) in accounts.chunks(batch_size).enumerate() {
        let txs: Vec<TxInput> = chunk.iter().map(|acc| {
            let tx = TxInput {
                tx_type: "transfer".to_string(),
                from: TREASURY_ADDRESS.to_string(),
                to: acc.address.clone(),
                amount: INIT_BALANCE,
                nonce: treasury_nonce,
            };
            treasury_nonce += 1;
            tx
        }).collect();

        match client
            .post(&config.node_rpc)
            .json(&RpcRequest {
                jsonrpc: "2.0",
                method: "x2_sendTransactionBatch",
                params: serde_json::json!([txs]),
                id: batch_idx as u64,
            })
            .send()
            .await
        {
            Ok(resp) => {
                if let Ok(rpc_resp) = resp.json::<RpcResponse>().await {
                    let success = rpc_resp.result.get("success")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0);
                    let failed = rpc_resp.result.get("failed")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0);
                    
                    if failed > 0 {
                        warn!("  Batch {}: {} success, {} failed", batch_idx, success, failed);
                    }
                }
            }
            Err(e) => {
                return Err(format!("Failed to send init batch {}: {}", batch_idx, e));
            }
        }
        
        // Small delay between batches
        if batch_idx % 10 == 9 {
            info!("  Progress: {}/{} batches sent", batch_idx + 1, (accounts.len() + batch_size - 1) / batch_size);
        }
    }
    
    // Wait a few blocks for init transactions to be included
    info!("  Waiting for init transactions to be included...");
    sleep(Duration::from_secs(6)).await;
    
    Ok(())
}

async fn run_benchmark(config: &Config, accounts: &mut [TestAccount], stats: Arc<Stats>) {
    let client = reqwest::Client::new();
    let mut rng = StdRng::seed_from_u64(12345);
    let batch_size = config.batch_size();
    let account_count = accounts.len();

    let batches_per_sec = (config.target_tps as f64 / batch_size as f64).ceil() as u64;
    let interval_ms = if batches_per_sec > 0 { 1000 / batches_per_sec } else { 1000 };
    let mut ticker = interval(Duration::from_millis(interval_ms.max(10)));

    info!("Starting benchmark: {} batches/sec, {} ms interval", batches_per_sec, interval_ms);
    info!("");

    loop {
        ticker.tick().await;

        // Generate batch of transactions between random accounts
        let txs: Vec<TxInput> = (0..batch_size)
            .map(|_| {
                let from_idx = rng.gen_range(0..account_count);
                let mut to_idx = rng.gen_range(0..account_count);
                while to_idx == from_idx {
                    to_idx = rng.gen_range(0..account_count);
                }
                
                let from_acc = &accounts[from_idx];
                let to_acc = &accounts[to_idx];
                
                let tx = TxInput {
                    tx_type: "transfer".to_string(),
                    from: from_acc.address.clone(),
                    to: to_acc.address.clone(),
                    amount: TRANSFER_AMOUNT,
                    nonce: from_acc.nonce,
                };
                
                // Note: we don't update nonce here to keep it simple
                // In production, we'd track nonces properly
                tx
            })
            .collect();

        let batch_len = txs.len() as u64;
        let send_start = Instant::now();

        match client
            .post(&config.node_rpc)
            .json(&RpcRequest {
                jsonrpc: "2.0",
                method: "x2_sendTransactionBatch",
                params: serde_json::json!([txs]),
                id: rng.gen(),
            })
            .send()
            .await
        {
            Ok(resp) => {
                let latency_ms = send_start.elapsed().as_millis() as u64;
                
                if let Ok(rpc_resp) = resp.json::<RpcResponse>().await {
                    let success = rpc_resp.result.get("success")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0);
                    let failed = rpc_resp.result.get("failed")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0);
                    
                    if success > 0 {
                        stats.record_success(success, latency_ms);
                    }
                    if failed > 0 {
                        stats.record_failure(failed);
                    }
                } else {
                    stats.record_failure(batch_len);
                }
            }
            Err(e) => {
                warn!("Failed to send batch: {}", e);
                stats.record_failure(batch_len);
            }
        }
    }
}

async fn reporter_loop(stats: Arc<Stats>, interval_secs: u64, start_time: Instant) {
    let mut ticker = interval(Duration::from_secs(interval_secs));
    let mut last_sent = 0u64;
    let mut last_time = start_time;

    loop {
        ticker.tick().await;

        let (sent, success, failed, total_latency) = stats.snapshot();
        let elapsed = start_time.elapsed().as_secs_f64();
        let delta_sent = sent - last_sent;
        let delta_time = last_time.elapsed().as_secs_f64();
        
        let current_tps = if delta_time > 0.0 { delta_sent as f64 / delta_time } else { 0.0 };
        let avg_tps = if elapsed > 0.0 { sent as f64 / elapsed } else { 0.0 };
        let avg_latency = if success > 0 { total_latency as f64 / success as f64 } else { 0.0 };
        let success_rate = if sent > 0 { success as f64 / sent as f64 * 100.0 } else { 0.0 };

        info!(
            "[{:>6.1}s] TPS: {:>7.1} (avg: {:>7.1}) | Sent: {:>8} | Success: {:>5.1}% | Latency: {:>5.1}ms",
            elapsed, current_tps, avg_tps, sent, success_rate, avg_latency
        );

        last_sent = sent;
        last_time = Instant::now();
    }
}

fn print_final_report(stats: &Stats, elapsed: Duration) {
    let (sent, success, failed, total_latency) = stats.snapshot();
    let elapsed_secs = elapsed.as_secs_f64();
    let avg_tps = if elapsed_secs > 0.0 { sent as f64 / elapsed_secs } else { 0.0 };
    let avg_latency = if success > 0 { total_latency as f64 / success as f64 } else { 0.0 };
    let success_rate = if sent > 0 { success as f64 / sent as f64 * 100.0 } else { 0.0 };

    info!("");
    info!("═══════════════════════════════════════════════════════════════");
    info!("                    BENCHMARK COMPLETE                         ");
    info!("═══════════════════════════════════════════════════════════════");
    info!("Duration:        {:.1}s", elapsed_secs);
    info!("───────────────────────────────────────────────────────────────");
    info!("Transactions:");
    info!("  Sent:          {}", sent);
    info!("  Success:       {} ({:.1}%)", success, success_rate);
    info!("  Failed:        {}", failed);
    info!("───────────────────────────────────────────────────────────────");
    info!("Performance:");
    info!("  Average TPS:   {:.1} tx/s", avg_tps);
    info!("  Avg Latency:   {:.1}ms", avg_latency);
    info!("═══════════════════════════════════════════════════════════════");
}
