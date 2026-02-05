//! State management

use std::collections::HashMap;
use serde::{Deserialize, Serialize};
use tiny_keccak::{Hasher, Keccak};
use xlayer_smt::{SmtProof, SparseMerkleTree};
use crate::types::{AccountState, Address, Amount, Hash};

/// State manager
#[derive(Clone, Debug)]
pub struct State {
    /// Account states
    accounts: HashMap<Address, AccountState>,
    /// SMT for state commitment
    smt: SparseMerkleTree,
}

impl State {
    /// Create a new empty state
    pub fn new() -> Self {
        Self {
            accounts: HashMap::new(),
            smt: SparseMerkleTree::new(),
        }
    }

    /// Get account state
    pub fn get_account(&self, address: &Address) -> AccountState {
        self.accounts.get(address).cloned().unwrap_or_default()
    }

    /// Set account state
    pub fn set_account(&mut self, address: Address, state: AccountState) {
        // Update account map
        self.accounts.insert(address, state.clone());
        
        // Update SMT
        self.smt.insert(address, state.to_bytes());
    }

    /// Get balance
    pub fn get_balance(&self, address: &Address) -> Amount {
        self.get_account(address).balance
    }

    /// Set balance
    pub fn set_balance(&mut self, address: Address, balance: Amount) {
        let mut account = self.get_account(&address);
        account.balance = balance;
        self.set_account(address, account);
    }

    /// Increment nonce
    pub fn increment_nonce(&mut self, address: &Address) {
        let mut account = self.get_account(address);
        account.nonce += 1;
        self.set_account(*address, account);
    }

    /// Get nonce
    pub fn get_nonce(&self, address: &Address) -> u64 {
        self.get_account(address).nonce
    }

    /// Get SMT root
    pub fn smt_root(&self) -> Hash {
        self.smt.root()
    }

    /// Generate SMT proof for an account
    pub fn get_proof(&self, address: &Address) -> Option<SmtProof> {
        self.smt.get_proof(address)
    }

    /// Compute state hash (incremental hash)
    pub fn compute_state_hash(&self, prev_hash: &Hash) -> Hash {
        let mut hasher = Keccak::v256();
        hasher.update(prev_hash);
        hasher.update(&self.smt_root());
        
        let mut output = [0u8; 32];
        hasher.finalize(&mut output);
        output
    }

    /// Get all touched accounts (for witness generation)
    pub fn get_touched_accounts(&self) -> Vec<(Address, AccountState)> {
        self.accounts.iter().map(|(k, v)| (*k, v.clone())).collect()
    }
}

impl Default for State {
    fn default() -> Self {
        Self::new()
    }
}

/// State witness for ZK proof
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StateWitness {
    /// Accounts involved in the block
    pub accounts: Vec<(Address, AccountState)>,
    /// SMT proofs for each account
    pub proofs: Vec<SmtProof>,
    /// SMT root before execution
    pub smt_root: Hash,
}

impl StateWitness {
    /// Verify all account states against SMT root
    pub fn verify(&self) -> bool {
        for (i, (address, account)) in self.accounts.iter().enumerate() {
            let proof = &self.proofs[i];
            if !proof.verify(&self.smt_root, address, &account.to_bytes()) {
                return false;
            }
        }
        true
    }
}
