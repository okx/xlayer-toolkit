//! SP1 Prover for generating ZK proofs

use anyhow::{Context, Result};
use sp1_sdk::{ProverClient, SP1Stdin, SP1ProofWithPublicValues};
use std::fs;
use tracing::{info, warn};

use crate::config::{Sp1Config, Sp1ProverMode};
use crate::witness::BlockWitness;

/// SP1 Prover wrapper
pub struct Sp1Prover {
    client: ProverClient,
    elf: Option<Vec<u8>>,
    config: Sp1Config,
}

impl Sp1Prover {
    /// Create a new prover with configuration
    pub fn new(config: Sp1Config) -> Self {
        let client = match config.prover_mode {
            Sp1ProverMode::Network => {
                info!("Using SP1 Network prover (succinct.xyz)");
                ProverClient::from_env()
            }
            Sp1ProverMode::Local => {
                info!("Using SP1 local prover");
                ProverClient::from_env()
            }
            Sp1ProverMode::Mock => {
                info!("Using SP1 mock prover (for testing)");
                ProverClient::from_env()
            }
        };

        // Load ELF if path is provided
        let elf = config.elf_path.as_ref().and_then(|path| {
            match fs::read(path) {
                Ok(data) => {
                    info!("Loaded ELF from: {}", path);
                    Some(data)
                }
                Err(e) => {
                    warn!("Failed to load ELF from {}: {}", path, e);
                    None
                }
            }
        });

        Self { client, elf, config }
    }

    /// Generate a proof for block verification
    pub fn prove(&self, witness: &BlockWitness) -> Result<ProofResult> {
        info!("Generating ZK proof for block {}", witness.block.number);

        // Check if we have ELF
        let elf = self.elf.as_ref()
            .context("ELF not loaded. Set ELF_PATH environment variable.")?;

        // Serialize witness
        let witness_bytes = serde_json::to_vec(witness)?;

        // Create SP1 stdin
        let mut stdin = SP1Stdin::new();
        stdin.write_slice(&witness_bytes);

        // Generate proof based on mode
        match self.config.prover_mode {
            Sp1ProverMode::Mock => {
                info!("Mock proving - returning placeholder proof");
                Ok(ProofResult {
                    proof_bytes: vec![0u8; 32],
                    public_values: vec![],
                    vkey: [0u8; 32],
                })
            }
            Sp1ProverMode::Local | Sp1ProverMode::Network => {
                info!("Setting up prover...");
                let (pk, vk) = self.client.setup(elf);
                
                info!("Generating proof (this may take a while)...");
                let proof = self.client.prove(&pk, &stdin)
                    .groth16()
                    .run()
                    .context("Failed to generate proof")?;

                info!("Proof generated successfully!");

                // Serialize proof
                let proof_bytes = bincode::serialize(&proof)
                    .context("Failed to serialize proof")?;

                // Get verification key bytes
                let vkey_bytes = vk.bytes32();

                Ok(ProofResult {
                    proof_bytes,
                    public_values: proof.public_values.to_vec(),
                    vkey: vkey_bytes,
                })
            }
        }
    }

    /// Verify a proof locally
    pub fn verify(&self, proof: &ProofResult) -> Result<bool> {
        let elf = self.elf.as_ref()
            .context("ELF not loaded")?;

        let (_, vk) = self.client.setup(elf);

        // Deserialize proof
        let sp1_proof: SP1ProofWithPublicValues = bincode::deserialize(&proof.proof_bytes)
            .context("Failed to deserialize proof")?;

        self.client.verify(&sp1_proof, &vk)
            .context("Proof verification failed")?;

        Ok(true)
    }

    /// Get the verification key for the loaded ELF
    pub fn get_vkey(&self) -> Result<[u8; 32]> {
        let elf = self.elf.as_ref()
            .context("ELF not loaded")?;

        let (_, vk) = self.client.setup(elf);
        Ok(vk.bytes32())
    }
}

impl Default for Sp1Prover {
    fn default() -> Self {
        Self::new(Sp1Config::default())
    }
}

/// Proof result
#[derive(Clone, Debug)]
pub struct ProofResult {
    /// Raw proof bytes (serialized SP1ProofWithPublicValues)
    pub proof_bytes: Vec<u8>,
    /// Public values (ABI encoded BlockOutput)
    pub public_values: Vec<u8>,
    /// Verification key (32 bytes)
    pub vkey: [u8; 32],
}

impl ProofResult {
    /// Get proof bytes for on-chain submission
    pub fn proof_bytes_for_contract(&self) -> Vec<u8> {
        // Extract just the Groth16 proof for on-chain verification
        // SP1 proof format may need adjustment based on verifier contract
        self.proof_bytes.clone()
    }
}
