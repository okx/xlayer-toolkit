//! Block structure

use serde::{Deserialize, Serialize};
use tiny_keccak::{Hasher, Keccak};
use crate::types::{BlockNumber, Hash};
use crate::tx::Transaction;

/// Block structure
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Block {
    /// Block number
    pub number: BlockNumber,
    /// Parent block hash
    pub parent_hash: Hash,
    /// Timestamp
    pub timestamp: u64,
    /// Transactions in this block
    pub transactions: Vec<Transaction>,
}

impl Block {
    /// Create a new block
    pub fn new(number: BlockNumber, parent_hash: Hash, timestamp: u64) -> Self {
        Self {
            number,
            parent_hash,
            timestamp,
            transactions: Vec::new(),
        }
    }

    /// Add a transaction
    pub fn add_transaction(&mut self, tx: Transaction) {
        self.transactions.push(tx);
    }

    /// Compute block hash
    pub fn hash(&self) -> Hash {
        let mut hasher = Keccak::v256();
        hasher.update(&self.number.to_le_bytes());
        hasher.update(&self.parent_hash);
        hasher.update(&self.timestamp.to_le_bytes());
        
        // Hash all transactions
        for tx in &self.transactions {
            hasher.update(&tx.hash());
        }
        
        let mut output = [0u8; 32];
        hasher.finalize(&mut output);
        output
    }

    /// Get transaction count
    pub fn tx_count(&self) -> u32 {
        self.transactions.len() as u32
    }
}

/// Block header (without transactions)
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BlockHeader {
    pub number: BlockNumber,
    pub parent_hash: Hash,
    pub timestamp: u64,
    pub tx_root: Hash,
    pub state_hash: Hash,
    pub trace_hash: Hash,
}

impl BlockHeader {
    /// Compute header hash
    pub fn hash(&self) -> Hash {
        let mut hasher = Keccak::v256();
        hasher.update(&self.number.to_le_bytes());
        hasher.update(&self.parent_hash);
        hasher.update(&self.timestamp.to_le_bytes());
        hasher.update(&self.tx_root);
        hasher.update(&self.state_hash);
        hasher.update(&self.trace_hash);
        
        let mut output = [0u8; 32];
        hasher.finalize(&mut output);
        output
    }
}
