//! Block executor

use crate::block::Block;
use crate::dex::{DexAccount, TransferError};
use crate::state::State;
use crate::trace::TraceHash;
use crate::tx::{Transaction, TxType};
use crate::types::{ExecutionResult, Hash, TxResult};

/// Block executor
pub struct BlockExecutor {
    state: State,
    trace: TraceHash,
    prev_state_hash: Hash,
}

impl BlockExecutor {
    /// Create a new executor with initial state
    pub fn new(state: State, prev_state_hash: Hash, prev_trace_hash: Hash) -> Self {
        Self {
            state,
            trace: TraceHash::from_hash(prev_trace_hash),
            prev_state_hash,
        }
    }

    /// Execute a block and return the result
    pub fn execute_block(&mut self, block: &Block) -> ExecutionResult {
        let mut success_count = 0u32;

        // Execute all transactions
        for tx in &block.transactions {
            let result = self.execute_tx(tx);
            if result.success {
                success_count += 1;
            }
        }

        // Compute new state hash
        let state_hash = self.state.compute_state_hash(&self.prev_state_hash);
        
        // Update trace hash
        let block_hash = block.hash();
        self.trace.update(&block_hash, &state_hash);

        ExecutionResult {
            state_hash,
            trace_hash: self.trace.current(),
            tx_count: block.tx_count(),
            success_count,
        }
    }

    /// Execute a single transaction
    pub fn execute_tx(&mut self, tx: &Transaction) -> TxResult {
        match tx.tx_type {
            TxType::Transfer => self.execute_transfer(tx),
            // Future: Handle other tx types
            _ => TxResult {
                success: false,
                from_balance: 0,
                to_balance: 0,
            },
        }
    }

    /// Execute a transfer transaction
    fn execute_transfer(&mut self, tx: &Transaction) -> TxResult {
        let from_state = self.state.get_account(&tx.from);
        let to_state = self.state.get_account(&tx.to);

        match DexAccount::transfer(&from_state, &to_state, tx.amount, tx.nonce) {
            Ok((new_from, new_to)) => {
                self.state.set_account(tx.from, new_from.clone());
                self.state.set_account(tx.to, new_to.clone());
                
                TxResult {
                    success: true,
                    from_balance: new_from.balance,
                    to_balance: new_to.balance,
                }
            }
            Err(_) => TxResult {
                success: false,
                from_balance: from_state.balance,
                to_balance: to_state.balance,
            },
        }
    }

    /// Get current state
    pub fn state(&self) -> &State {
        &self.state
    }

    /// Get current trace hash
    pub fn trace_hash(&self) -> Hash {
        self.trace.current()
    }

    /// Get SMT root
    pub fn smt_root(&self) -> Hash {
        self.state.smt_root()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::AccountState;

    #[test]
    fn test_execute_transfer() {
        let mut state = State::new();
        
        let from = [1u8; 32];
        let to = [2u8; 32];
        
        // Set initial balance
        state.set_account(from, AccountState { balance: 1000, nonce: 0 });
        
        let mut executor = BlockExecutor::new(state, [0u8; 32], [0u8; 32]);
        
        let tx = Transaction::transfer(from, to, 100, 0);
        let result = executor.execute_tx(&tx);
        
        assert!(result.success);
        assert_eq!(result.from_balance, 900);
        assert_eq!(result.to_balance, 100);
    }
}
