//! SP1 Prover for generating ZK proofs

use anyhow::{Context, Result};
use sp1_sdk::{EnvProver, HashableKey, ProverClient, SP1Stdin, SP1ProofWithPublicValues};
use std::fs;
use tracing::{info, warn};

use crate::config::Sp1Config;
use crate::witness::BlockWitness;

/// SP1 Prover wrapper
pub struct Sp1Prover {
    /// SP1 client - only initialized for SP1 mode (not mock)
    client: Option<EnvProver>,
    elf: Option<Vec<u8>>,
    config: Sp1Config,
}

impl Sp1Prover {
    /// Create a new prover with configuration
    pub fn new(config: Sp1Config) -> Self {
        // Only initialize SP1 client for SP1 mode (not mock)
        // This avoids requiring SP1_PRIVATE_KEY when using mock mode
        let client = if config.prover_mode.is_mock() {
            info!("SP1 prover initialized in MOCK mode (no SP1 SDK needed)");
            None
        } else {
            // Check if SP1_PRIVATE_KEY is set
            if config.private_key.is_none() {
                warn!("SP1_PRIVATE_KEY not set, falling back to MOCK mode");
                info!("SP1 prover initialized in MOCK mode (SP1_PRIVATE_KEY not provided)");
                return Self { client: None, elf: None, config: Sp1Config { prover_mode: crate::config::Sp1ProverMode(false), ..config } };
            }
            
            info!("SP1 prover initialized in SP1 NETWORK mode");
            // Set SP1_PROVER to "network" for sp1-sdk (it expects mock/cpu/cuda/network, not true/false)
            std::env::set_var("SP1_PROVER", "network");
            // Map SP1_PRIVATE_KEY to NETWORK_PRIVATE_KEY for sp1-sdk
            if let Some(ref pk) = config.private_key {
                std::env::set_var("NETWORK_PRIVATE_KEY", pk);
            }
            Some(ProverClient::from_env())
        };

        // Load ELF if path is provided (only needed for SP1 mode)
        let elf = if config.prover_mode.is_sp1() {
            config.elf_path.as_ref().and_then(|path| {
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
            })
        } else {
            None
        };

        Self { client, elf, config }
    }

    /// Generate a proof for block verification
    pub fn prove(&self, witness: &BlockWitness) -> Result<ProofResult> {
        info!("Generating ZK proof for block {}", witness.block.number);

        if self.config.prover_mode.is_mock() {
            // Mock mode - no ELF required, generate mock proof directly
            info!("Mock proving - generating mock proof with valid public_values");
            
            // Generate mock public values that match the expected BlockOutput format
            // This allows testing the full flow without real proving
            let mock_output = MockBlockOutput {
                block_number: witness.block.number,
                block_hash: witness.block.hash(),
                state_hash: witness.prev_state_hash,
                trace_hash: witness.prev_trace_hash,
                smt_root: witness.prev_smt_root,
                success_count: witness.block.transactions.len() as u32,
            };
            
            // ABI encode the mock output for Solidity compatibility
            let public_values = mock_output.abi_encode();
            
            Ok(ProofResult {
                proof_bytes: vec![0u8; 256],  // Mock proof bytes
                public_values,
                vkey: [0u8; 32],
            })
        } else {
            // SP1 mode - ELF and client required
            let client = self.client.as_ref()
                .context("SP1 client not initialized")?;
            let elf = self.elf.as_ref()
                .context("ELF not loaded. Run 'make build-elf' first or check ELF_PATH.")?;

            // Create SP1 stdin and write witness
            // Use write() which automatically serializes with bincode
            // Guest uses sp1_zkvm::io::read() which expects bincode format
            let mut stdin = SP1Stdin::new();
            stdin.write(&witness);

            info!("Setting up prover...");
            let (pk, vk) = client.setup(elf);
            
            info!("Generating Groth16 proof (this may take a while)...");
            let proof = client.prove(&pk, &stdin)
                .groth16()
                .run()
                .context("Failed to generate proof")?;

            info!("Proof generated successfully!");

            // Get the raw proof bytes for on-chain submission
            // SP1 Groth16 proofs use proof.bytes() for the verifier contract
            let proof_bytes = proof.bytes();

            // Get verification key bytes
            let vkey_bytes = vk.bytes32_raw();

            Ok(ProofResult {
                proof_bytes,
                public_values: proof.public_values.to_vec(),
                vkey: vkey_bytes,
            })
        }
    }

    /// Verify a proof locally (only works for SP1 mode)
    pub fn verify(&self, proof: &ProofResult) -> Result<bool> {
        if self.config.prover_mode.is_mock() {
            info!("Mock mode: skipping local verification");
            return Ok(true);
        }
        
        let client = self.client.as_ref()
            .context("SP1 client not initialized")?;
        let elf = self.elf.as_ref()
            .context("ELF not loaded")?;

        let (_, vk) = client.setup(elf);

        // Deserialize proof
        let sp1_proof: SP1ProofWithPublicValues = bincode::deserialize(&proof.proof_bytes)
            .context("Failed to deserialize proof")?;

        client.verify(&sp1_proof, &vk)
            .context("Proof verification failed")?;

        Ok(true)
    }

    /// Get the verification key for the loaded ELF
    pub fn get_vkey(&self) -> Result<[u8; 32]> {
        let client = self.client.as_ref()
            .context("SP1 client not initialized (mock mode doesn't have vkey)")?;
        let elf = self.elf.as_ref()
            .context("ELF not loaded")?;

        let (_, vk) = client.setup(elf);
        Ok(vk.bytes32_raw())
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
    /// Raw proof bytes for on-chain verification
    pub proof_bytes: Vec<u8>,
    /// Public values (ABI encoded BlockOutput)
    pub public_values: Vec<u8>,
    /// Verification key (32 bytes)
    pub vkey: [u8; 32],
}

/// Mock block output for testing
/// Matches the BlockOutput struct in the zkVM program
struct MockBlockOutput {
    block_number: u64,
    block_hash: [u8; 32],
    state_hash: [u8; 32],
    trace_hash: [u8; 32],
    smt_root: [u8; 32],
    success_count: u32,
}

impl MockBlockOutput {
    /// ABI encode for Solidity compatibility
    /// struct BlockOutput { uint64 blockNumber; bytes32 blockHash; bytes32 stateHash; 
    ///                      bytes32 traceHash; bytes32 smtRoot; uint32 successCount; }
    fn abi_encode(&self) -> Vec<u8> {
        let mut encoded = Vec::with_capacity(192);
        
        // blockNumber (uint64 padded to 32 bytes)
        let mut block_bytes = [0u8; 32];
        block_bytes[24..32].copy_from_slice(&self.block_number.to_be_bytes());
        encoded.extend_from_slice(&block_bytes);
        
        // blockHash (bytes32)
        encoded.extend_from_slice(&self.block_hash);
        
        // stateHash (bytes32)
        encoded.extend_from_slice(&self.state_hash);
        
        // traceHash (bytes32)
        encoded.extend_from_slice(&self.trace_hash);
        
        // smtRoot (bytes32)
        encoded.extend_from_slice(&self.smt_root);
        
        // successCount (uint32 padded to 32 bytes)
        let mut count_bytes = [0u8; 32];
        count_bytes[28..32].copy_from_slice(&self.success_count.to_be_bytes());
        encoded.extend_from_slice(&count_bytes);
        
        encoded
    }
}
