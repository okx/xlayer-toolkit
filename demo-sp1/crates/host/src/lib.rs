//! Host-side logic for xlayer-dex ZK Bisection

pub mod proposer;
pub mod challenger;
pub mod bisection;
pub mod witness;
pub mod config;

// Prover module - use mock by default, sp1 when feature enabled
#[cfg(feature = "sp1")]
pub mod prover;
#[cfg(not(feature = "sp1"))]
pub mod prover_mock;

#[cfg(feature = "sp1")]
pub use prover::Sp1Prover as Prover;
#[cfg(not(feature = "sp1"))]
pub use prover_mock::MockSp1Prover as Prover;

pub use proposer::Proposer;
pub use challenger::Challenger;
pub use bisection::BisectionManager;
pub use witness::WitnessGenerator;
pub use config::Config;
