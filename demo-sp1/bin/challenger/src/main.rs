//! Challenger binary

use anyhow::Result;
use tracing::{info, Level};
use tracing_subscriber::FmtSubscriber;

use xlayer_host::{Challenger, Config};

#[tokio::main]
async fn main() -> Result<()> {
    // Setup logging
    let subscriber = FmtSubscriber::builder()
        .with_max_level(Level::INFO)
        .finish();
    tracing::subscriber::set_global_default(subscriber)?;

    info!("╔═══════════════════════════════════════════════╗");
    info!("║       xlayer-dex ZK Bisection Challenger      ║");
    info!("╚═══════════════════════════════════════════════╝");

    // Load config from environment
    let mut config = Config::from_env();
    config.is_proposer = false;

    info!("");
    info!("Configuration:");
    info!("  L1 RPC:           {}", config.l1_rpc);
    info!("  L2 RPC:           {}", config.l2_rpc);
    info!("  Challenge every:  {} outputs", config.challenge_every_n_outputs);
    info!("");
    info!("Features:");
    info!("  ✓ Monitor batch outputs for validity");
    info!("  ✓ Challenge invalid batches");
    info!("  ✓ Participate in Bisection (~10 rounds)");
    info!("  ✓ Claim rewards on winning / timeout");
    info!("");

    // Create and run challenger
    let mut challenger = Challenger::new(config);
    
    info!("Challenger starting main loop...");
    challenger.run().await
}
