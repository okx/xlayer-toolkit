//! Mock SP1 Prover for testing without sp1-sdk dependency

use anyhow::Result;
use tracing::info;

use crate::config::Sp1Config;
use crate::witness::BlockWitness;

/// Mock SP1 Prover (no actual proving)
pub struct MockSp1Prover {
    #[allow(dead_code)]
    config: Sp1Config,
}

impl MockSp1Prover {
    /// Create a new mock prover
    pub fn new(config: Sp1Config) -> Self {
        info!("Using Mock SP1 Prover (no actual proving)");
        Self { config }
    }

    /// Generate a mock proof for block verification
    pub fn prove(&self, witness: &BlockWitness) -> Result<ProofResult> {
        info!("Mock proving block {}", witness.block.number);

        // Return mock proof
        Ok(ProofResult {
            proof_bytes: vec![0u8; 256], // Fake proof bytes
            public_values: serde_json::to_vec(&MockBlockOutput {
                block_number: witness.block.number,
                block_hash: witness.block.hash(),
                state_hash: [0u8; 32],
                trace_hash: [0u8; 32],
                smt_root: witness.prev_smt_root,
                success_count: witness.block.transactions.len() as u32,
            })?,
            vkey: [0u8; 32],
        })
    }

    /// Verify a proof (always returns true for mock)
    pub fn verify(&self, _proof: &ProofResult) -> Result<bool> {
        Ok(true)
    }

    /// Get mock verification key
    pub fn get_vkey(&self) -> Result<[u8; 32]> {
        Ok([0u8; 32])
    }
}

impl Default for MockSp1Prover {
    fn default() -> Self {
        Self::new(Sp1Config::default())
    }
}

/// Proof result (same structure as real prover)
#[derive(Clone, Debug)]
pub struct ProofResult {
    pub proof_bytes: Vec<u8>,
    pub public_values: Vec<u8>,
    pub vkey: [u8; 32],
}

/// Mock block output for public values
#[derive(serde::Serialize)]
struct MockBlockOutput {
    block_number: u64,
    block_hash: [u8; 32],
    state_hash: [u8; 32],
    trace_hash: [u8; 32],
    smt_root: [u8; 32],
    success_count: u32,
}
