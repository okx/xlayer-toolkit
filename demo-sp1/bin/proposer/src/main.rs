//! Proposer binary

use anyhow::Result;
use tracing::{info, Level};
use tracing_subscriber::FmtSubscriber;

use xlayer_host::{Config, Proposer};

#[tokio::main]
async fn main() -> Result<()> {
    // Setup logging
    let subscriber = FmtSubscriber::builder()
        .with_max_level(Level::INFO)
        .finish();
    tracing::subscriber::set_global_default(subscriber)?;

    info!("╔═══════════════════════════════════════════════╗");
    info!("║       xlayer-dex ZK Bisection Proposer        ║");
    info!("╚═══════════════════════════════════════════════╝");

    // Load config from environment
    let mut config = Config::from_env();
    config.is_proposer = true;

    info!("");
    info!("Configuration:");
    info!("  L1 RPC:         {}", config.l1_rpc);
    info!("  L2 RPC:         {}", config.l2_rpc);
    info!("  Batch interval: {} blocks", config.batch_interval);
    info!("  SP1 mode:       {:?}", config.sp1.prover_mode);
    info!("");
    info!("Features:");
    info!("  ✓ Submit batch outputs to L1");
    info!("  ✓ Handle challenges via Bisection (~10 rounds)");
    info!("  ✓ Generate ZK proofs for disputed blocks");
    info!("");

    // Create and run proposer
    let mut proposer = Proposer::new(config);
    
    info!("Proposer starting main loop...");
    proposer.run().await
}
