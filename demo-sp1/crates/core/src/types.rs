//! Common types

use serde::{Deserialize, Serialize};

/// 32-byte hash type
pub type Hash = [u8; 32];

/// Address type (20 bytes, padded to 32 for SMT)
pub type Address = [u8; 32];

/// Amount type (u128 for large balances)
pub type Amount = u128;

/// Block number type
pub type BlockNumber = u64;

/// Transaction index within a block
pub type TxIndex = u32;

/// Account state
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct AccountState {
    pub balance: Amount,
    pub nonce: u64,
}

impl AccountState {
    pub fn to_bytes(&self) -> [u8; 32] {
        let mut bytes = [0u8; 32];
        bytes[0..16].copy_from_slice(&self.balance.to_le_bytes());
        bytes[16..24].copy_from_slice(&self.nonce.to_le_bytes());
        bytes
    }

    pub fn from_bytes(bytes: &[u8; 32]) -> Self {
        let balance = u128::from_le_bytes(bytes[0..16].try_into().unwrap());
        let nonce = u64::from_le_bytes(bytes[16..24].try_into().unwrap());
        Self { balance, nonce }
    }
}

/// Block execution result
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ExecutionResult {
    pub state_hash: Hash,
    pub trace_hash: Hash,
    pub tx_count: u32,
    pub success_count: u32,
}

/// Transaction result
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TxResult {
    pub success: bool,
    pub from_balance: Amount,
    pub to_balance: Amount,
}
