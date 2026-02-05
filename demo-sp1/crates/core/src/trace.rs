//! Trace hash for Bisection

use serde::{Deserialize, Serialize};
use tiny_keccak::{Hasher, Keccak};
use crate::types::Hash;

/// Trace hash calculator
/// 
/// trace_hash_N = H(trace_hash_{N-1}, block_hash_N, state_hash_N)
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct TraceHash {
    /// Current trace hash
    current: Hash,
}

impl TraceHash {
    /// Create a new trace hash with initial value (zero)
    pub fn new() -> Self {
        Self {
            current: [0u8; 32],
        }
    }

    /// Create from existing hash
    pub fn from_hash(hash: Hash) -> Self {
        Self { current: hash }
    }

    /// Update trace hash with new block
    pub fn update(&mut self, block_hash: &Hash, state_hash: &Hash) {
        let mut hasher = Keccak::v256();
        hasher.update(&self.current);
        hasher.update(block_hash);
        hasher.update(state_hash);
        hasher.finalize(&mut self.current);
    }

    /// Get current trace hash
    pub fn current(&self) -> Hash {
        self.current
    }

    /// Compute trace hash for a single block (static method)
    pub fn compute(prev_trace: &Hash, block_hash: &Hash, state_hash: &Hash) -> Hash {
        let mut hasher = Keccak::v256();
        hasher.update(prev_trace);
        hasher.update(block_hash);
        hasher.update(state_hash);
        
        let mut output = [0u8; 32];
        hasher.finalize(&mut output);
        output
    }
}

/// Trace entry for a single block
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TraceEntry {
    pub block_number: u64,
    pub block_hash: Hash,
    pub state_hash: Hash,
    pub trace_hash: Hash,
}

/// Trace log for Bisection
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct TraceLog {
    pub entries: Vec<TraceEntry>,
}

impl TraceLog {
    pub fn new() -> Self {
        Self { entries: Vec::new() }
    }

    pub fn add_entry(&mut self, entry: TraceEntry) {
        self.entries.push(entry);
    }

    /// Get trace hash at specific block number
    pub fn get_trace_at(&self, block_number: u64) -> Option<Hash> {
        self.entries
            .iter()
            .find(|e| e.block_number == block_number)
            .map(|e| e.trace_hash)
    }

    /// Get entry at specific block number
    pub fn get_entry_at(&self, block_number: u64) -> Option<&TraceEntry> {
        self.entries.iter().find(|e| e.block_number == block_number)
    }
}
