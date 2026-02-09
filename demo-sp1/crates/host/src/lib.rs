//! Host-side logic for xlayer-dex ZK Bisection

pub mod proposer;
pub mod challenger;
pub mod bisection;
pub mod witness;
pub mod config;
pub mod prover;

// Export Sp1Prover as Prover
// Prover mode (mock/local/network) is controlled by SP1_PROVER environment variable
pub use prover::Sp1Prover as Prover;

pub use proposer::Proposer;
pub use challenger::Challenger;
pub use bisection::BisectionManager;
pub use witness::WitnessGenerator;
pub use config::Config;
