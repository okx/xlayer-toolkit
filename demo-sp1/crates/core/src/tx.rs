//! Transaction structure

use serde::{Deserialize, Serialize};
use tiny_keccak::{Hasher, Keccak};
use crate::types::{Address, Amount, Hash};

/// Transaction type
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum TxType {
    /// Transfer tokens from one account to another
    Transfer,
    /// DEX swap (future)
    Swap,
    /// DEX add liquidity (future)
    AddLiquidity,
    /// DEX remove liquidity (future)
    RemoveLiquidity,
}

/// Transaction structure
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Transaction {
    /// Transaction type
    pub tx_type: TxType,
    /// Sender address
    pub from: Address,
    /// Receiver address
    pub to: Address,
    /// Amount to transfer
    pub amount: Amount,
    /// Sender's nonce
    pub nonce: u64,
}

impl Transaction {
    /// Create a new transfer transaction
    pub fn transfer(from: Address, to: Address, amount: Amount, nonce: u64) -> Self {
        Self {
            tx_type: TxType::Transfer,
            from,
            to,
            amount,
            nonce,
        }
    }

    /// Compute transaction hash
    pub fn hash(&self) -> Hash {
        let mut hasher = Keccak::v256();
        
        // Hash tx type
        let tx_type_byte = match self.tx_type {
            TxType::Transfer => 0u8,
            TxType::Swap => 1u8,
            TxType::AddLiquidity => 2u8,
            TxType::RemoveLiquidity => 3u8,
        };
        hasher.update(&[tx_type_byte]);
        
        hasher.update(&self.from);
        hasher.update(&self.to);
        hasher.update(&self.amount.to_le_bytes());
        hasher.update(&self.nonce.to_le_bytes());
        
        let mut output = [0u8; 32];
        hasher.finalize(&mut output);
        output
    }
}
