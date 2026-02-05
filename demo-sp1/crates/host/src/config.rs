//! Configuration

use serde::{Deserialize, Serialize};
use std::env;

/// SP1 Prover mode
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub enum Sp1ProverMode {
    /// Use local proving (slow, no cost)
    Local,
    /// Use Succinct Network (fast, requires SP1_PRIVATE_KEY)
    Network,
    /// Mock proving (for testing, instant)
    Mock,
}

impl Default for Sp1ProverMode {
    fn default() -> Self {
        Self::Mock
    }
}

impl From<&str> for Sp1ProverMode {
    fn from(s: &str) -> Self {
        match s.to_lowercase().as_str() {
            "local" => Self::Local,
            "network" => Self::Network,
            _ => Self::Mock,
        }
    }
}

/// SP1 configuration
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Sp1Config {
    /// Prover mode
    pub prover_mode: Sp1ProverMode,
    /// SP1 Network private key (required for Network mode)
    /// Get from https://network.succinct.xyz/
    pub private_key: Option<String>,
    /// Block verify program ELF path
    pub elf_path: Option<String>,
}

impl Default for Sp1Config {
    fn default() -> Self {
        Self {
            prover_mode: Sp1ProverMode::Mock,
            private_key: None,
            elf_path: None,
        }
    }
}

impl Sp1Config {
    /// Load from environment variables
    pub fn from_env() -> Self {
        let prover_mode = env::var("SP1_PROVER")
            .map(|s| Sp1ProverMode::from(s.as_str()))
            .unwrap_or_default();
        
        let private_key = env::var("SP1_PRIVATE_KEY").ok();
        let elf_path = env::var("ELF_PATH").ok();

        Self {
            prover_mode,
            private_key,
            elf_path,
        }
    }
}

/// Host configuration
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Config {
    /// L1 RPC URL
    pub l1_rpc: String,
    /// L2 RPC URL (for fetching block data)
    pub l2_rpc: String,
    /// Output Oracle contract address
    pub output_oracle_address: Option<String>,
    /// Dispute Game Factory address
    pub dispute_game_factory: String,
    /// SP1 Verifier address
    pub sp1_verifier: String,
    /// Block verify program verification key
    pub block_verify_vkey: String,
    /// Private key for signing transactions
    pub private_key: String,
    /// Proposer address (for Anvil unlocked account)
    pub proposer_address: Option<String>,
    /// Fetch interval in seconds
    pub fetch_interval: u64,
    /// Whether this is a proposer or challenger
    pub is_proposer: bool,
    /// Batch interval (blocks per batch)
    pub batch_interval: u64,
    /// Challenge every N outputs (for demo)
    pub challenge_every_n_outputs: u64,
    /// Force challenge even if output is valid (for demo/testing)
    pub force_challenge: bool,
    /// SP1 configuration
    pub sp1: Sp1Config,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            l1_rpc: "http://localhost:8545".to_string(),
            l2_rpc: "http://localhost:8546".to_string(),
            output_oracle_address: None,
            dispute_game_factory: "0x0000000000000000000000000000000000000000".to_string(),
            sp1_verifier: "0x0000000000000000000000000000000000000000".to_string(),
            block_verify_vkey: "".to_string(),
            private_key: "".to_string(),
            proposer_address: None,
            fetch_interval: 10,
            is_proposer: false,
            batch_interval: 100,
            challenge_every_n_outputs: 100,
            force_challenge: false,
            sp1: Sp1Config::default(),
        }
    }
}

impl Config {
    /// Load from environment variables
    pub fn from_env() -> Self {
        Self {
            l1_rpc: env::var("L1_RPC").unwrap_or_else(|_| "http://localhost:8545".to_string()),
            l2_rpc: env::var("L2_RPC").unwrap_or_else(|_| "http://localhost:8546".to_string()),
            output_oracle_address: env::var("OUTPUT_ORACLE_ADDRESS").ok(),
            dispute_game_factory: env::var("DISPUTE_GAME_FACTORY_ADDRESS").unwrap_or_default(),
            sp1_verifier: env::var("SP1_VERIFIER_ADDRESS").unwrap_or_default(),
            block_verify_vkey: env::var("BLOCK_VERIFY_VKEY").unwrap_or_default(),
            private_key: env::var("PRIVATE_KEY").unwrap_or_default(),
            proposer_address: env::var("PROPOSER_ADDRESS").ok(),
            fetch_interval: env::var("FETCH_INTERVAL")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(10),
            is_proposer: env::var("IS_PROPOSER")
                .map(|s| s == "true" || s == "1")
                .unwrap_or(false),
            batch_interval: env::var("BATCH_INTERVAL")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(100),
            challenge_every_n_outputs: env::var("CHALLENGE_EVERY_N_OUTPUTS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(100),
            force_challenge: env::var("FORCE_CHALLENGE")
                .map(|s| s == "true" || s == "1")
                .unwrap_or(true), // Default to true for demo
            sp1: Sp1Config::from_env(),
        }
    }
}
