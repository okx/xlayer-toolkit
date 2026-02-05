//! Contract bindings
//! 
//! This crate will contain generated bindings from Solidity contracts.
//! For now, we define the interface types manually.

use serde::{Deserialize, Serialize};

/// Output structure from OutputOracle
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Output {
    pub state_hash: [u8; 32],
    pub trace_hash: [u8; 32],
    pub smt_root: [u8; 32],
    pub start_block: u64,
    pub end_block: u64,
    pub timestamp: u64,
    pub proposer: [u8; 20],
}

/// Game status
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum GameStatus {
    InProgress = 0,
    ChallengerWins = 1,
    DefenderWins = 2,
}

/// Bisection status
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum BisectionStatus {
    NotStarted = 0,
    InProgress = 1,
    Completed = 2,
}

/// Block output (public values from ZK proof)
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BlockOutput {
    pub block_number: u64,
    pub block_hash: [u8; 32],
    pub state_hash: [u8; 32],
    pub trace_hash: [u8; 32],
    pub smt_root: [u8; 32],
    pub success_count: u32,
}
