//! DEX account logic

use crate::types::{AccountState, Amount};

/// DEX account operations
pub struct DexAccount;

impl DexAccount {
    /// Transfer tokens from one account to another
    pub fn transfer(
        from_state: &AccountState,
        to_state: &AccountState,
        amount: Amount,
        expected_nonce: u64,
    ) -> Result<(AccountState, AccountState), TransferError> {
        // Check nonce
        if from_state.nonce != expected_nonce {
            return Err(TransferError::InvalidNonce {
                expected: expected_nonce,
                actual: from_state.nonce,
            });
        }

        // Check balance
        if from_state.balance < amount {
            return Err(TransferError::InsufficientBalance {
                required: amount,
                available: from_state.balance,
            });
        }

        // Execute transfer
        let new_from = AccountState {
            balance: from_state.balance - amount,
            nonce: from_state.nonce + 1,
        };

        let new_to = AccountState {
            balance: to_state.balance + amount,
            nonce: to_state.nonce,
        };

        Ok((new_from, new_to))
    }
}

/// Transfer error types
#[derive(Debug, Clone)]
pub enum TransferError {
    InvalidNonce { expected: u64, actual: u64 },
    InsufficientBalance { required: Amount, available: Amount },
}
