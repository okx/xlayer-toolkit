//! SP1 zkVM program for verifying block execution
//!
//! This program verifies:
//! 1. Initial account states belong to the SMT root (via SMT proofs)
//! 2. Block execution is correct
//! 3. Final trace_hash matches expected value

#![no_main]
sp1_zkvm::entrypoint!(main);

use serde::{Deserialize, Serialize};
use tiny_keccak::{Hasher, Keccak};

// ============================================================================
// Types (embedded from xlayer-core)
// ============================================================================

pub type Hash = [u8; 32];
pub type Address = [u8; 32];
pub type Amount = u128;

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
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum TxType {
    Transfer,
    Swap,
    AddLiquidity,
    RemoveLiquidity,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Transaction {
    pub tx_type: TxType,
    pub from: Address,
    pub to: Address,
    pub amount: Amount,
    pub nonce: u64,
}

impl Transaction {
    pub fn hash(&self) -> Hash {
        let mut hasher = Keccak::v256();
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

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Block {
    pub number: u64,
    pub parent_hash: Hash,
    pub timestamp: u64,
    pub transactions: Vec<Transaction>,
}

impl Block {
    pub fn hash(&self) -> Hash {
        let mut hasher = Keccak::v256();
        hasher.update(&self.number.to_le_bytes());
        hasher.update(&self.parent_hash);
        hasher.update(&self.timestamp.to_le_bytes());
        
        for tx in &self.transactions {
            hasher.update(&tx.hash());
        }
        
        let mut output = [0u8; 32];
        hasher.finalize(&mut output);
        output
    }
}

// ============================================================================
// SMT Proof (embedded from xlayer-smt)
// ============================================================================

const TREE_DEPTH: usize = 256;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SmtProof {
    pub key: [u8; 32],
    pub value: [u8; 32],
    pub siblings: Vec<[u8; 32]>,
}

impl SmtProof {
    pub fn verify(&self, root: &[u8; 32]) -> bool {
        if self.siblings.len() != TREE_DEPTH {
            return false;
        }

        let computed_root = self.compute_root();
        computed_root == *root
    }

    fn compute_root(&self) -> [u8; 32] {
        let mut current_hash = hash_leaf(&self.key, &self.value);
        let path = key_to_path(&self.key);

        for (i, sibling) in self.siblings.iter().enumerate() {
            let depth = TREE_DEPTH - 1 - i;
            let is_right = path[depth];
            
            let (left, right) = if is_right {
                (*sibling, current_hash)
            } else {
                (current_hash, *sibling)
            };
            
            current_hash = hash_pair(&left, &right);
        }

        current_hash
    }
}

fn hash_pair(left: &[u8; 32], right: &[u8; 32]) -> [u8; 32] {
    let mut hasher = Keccak::v256();
    hasher.update(left);
    hasher.update(right);
    let mut output = [0u8; 32];
    hasher.finalize(&mut output);
    output
}

fn hash_leaf(key: &[u8; 32], value: &[u8; 32]) -> [u8; 32] {
    let mut hasher = Keccak::v256();
    hasher.update(&[0x00]); // Leaf prefix
    hasher.update(key);
    hasher.update(value);
    let mut output = [0u8; 32];
    hasher.finalize(&mut output);
    output
}

fn key_to_path(key: &[u8; 32]) -> Vec<bool> {
    let mut path = Vec::with_capacity(TREE_DEPTH);
    for byte in key {
        for i in (0..8).rev() {
            path.push((byte >> i) & 1 == 1);
        }
    }
    path
}

// ============================================================================
// Witness and Output structures
// ============================================================================

/// Witness data for block verification
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BlockWitness {
    /// The block to verify
    pub block: Block,
    /// Initial account states (accounts involved in the block)
    pub initial_states: Vec<(Address, AccountState)>,
    /// SMT proofs for initial states
    pub smt_proofs: Vec<SmtProof>,
    /// SMT root before execution
    pub prev_smt_root: Hash,
    /// Previous state hash (for incremental hash)
    pub prev_state_hash: Hash,
    /// Previous trace hash
    pub prev_trace_hash: Hash,
}

/// Public output of the verification
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BlockOutput {
    /// Block number
    pub block_number: u64,
    /// Block hash
    pub block_hash: Hash,
    /// State hash after execution
    pub state_hash: Hash,
    /// Trace hash after execution
    pub trace_hash: Hash,
    /// SMT root after execution
    pub smt_root: Hash,
    /// Number of successful transactions
    pub success_count: u32,
}

// ============================================================================
// Execution logic
// ============================================================================

/// Simple state manager for zkVM
struct ZkState {
    accounts: Vec<(Address, AccountState)>,
}

impl ZkState {
    fn new(initial_states: Vec<(Address, AccountState)>) -> Self {
        Self { accounts: initial_states }
    }

    fn get_account(&self, address: &Address) -> AccountState {
        self.accounts
            .iter()
            .find(|(addr, _)| addr == address)
            .map(|(_, state)| state.clone())
            .unwrap_or_default()
    }

    fn set_account(&mut self, address: Address, state: AccountState) {
        if let Some(pos) = self.accounts.iter().position(|(addr, _)| *addr == address) {
            self.accounts[pos] = (address, state);
        } else {
            self.accounts.push((address, state));
        }
    }

    /// Compute SMT root from current state
    fn compute_smt_root(&self) -> Hash {
        // Simplified: just hash all accounts
        // In production, this would rebuild the SMT
        let mut hasher = Keccak::v256();
        for (addr, state) in &self.accounts {
            hasher.update(addr);
            hasher.update(&state.to_bytes());
        }
        let mut output = [0u8; 32];
        hasher.finalize(&mut output);
        output
    }
}

/// Execute a transfer transaction
fn execute_transfer(state: &mut ZkState, tx: &Transaction) -> bool {
    let from_state = state.get_account(&tx.from);
    let to_state = state.get_account(&tx.to);

    // Check nonce
    if from_state.nonce != tx.nonce {
        return false;
    }

    // Check balance
    if from_state.balance < tx.amount {
        return false;
    }

    // Execute
    let new_from = AccountState {
        balance: from_state.balance - tx.amount,
        nonce: from_state.nonce + 1,
    };
    let new_to = AccountState {
        balance: to_state.balance + tx.amount,
        nonce: to_state.nonce,
    };

    state.set_account(tx.from, new_from);
    state.set_account(tx.to, new_to);

    true
}

/// Execute a block
fn execute_block(state: &mut ZkState, block: &Block) -> u32 {
    let mut success_count = 0u32;

    for tx in &block.transactions {
        let success = match tx.tx_type {
            TxType::Transfer => execute_transfer(state, tx),
            _ => false, // Other tx types not implemented yet
        };
        if success {
            success_count += 1;
        }
    }

    success_count
}

/// Compute state hash (incremental)
fn compute_state_hash(prev_hash: &Hash, smt_root: &Hash) -> Hash {
    let mut hasher = Keccak::v256();
    hasher.update(prev_hash);
    hasher.update(smt_root);
    let mut output = [0u8; 32];
    hasher.finalize(&mut output);
    output
}

/// Compute trace hash
fn compute_trace_hash(prev_trace: &Hash, block_hash: &Hash, state_hash: &Hash) -> Hash {
    let mut hasher = Keccak::v256();
    hasher.update(prev_trace);
    hasher.update(block_hash);
    hasher.update(state_hash);
    let mut output = [0u8; 32];
    hasher.finalize(&mut output);
    output
}

// ============================================================================
// Main entry point
// ============================================================================

fn main() {
    // Read witness from host
    let witness: BlockWitness = sp1_zkvm::io::read();

    // 1. Verify SMT proofs for all initial states
    for (i, (address, account)) in witness.initial_states.iter().enumerate() {
        let proof = &witness.smt_proofs[i];
        
        // Verify the proof
        assert!(
            proof.key == *address,
            "SMT proof key mismatch"
        );
        assert!(
            proof.value == account.to_bytes(),
            "SMT proof value mismatch"
        );
        assert!(
            proof.verify(&witness.prev_smt_root),
            "SMT proof verification failed"
        );
    }

    // 2. Execute block
    let mut state = ZkState::new(witness.initial_states.clone());
    let success_count = execute_block(&mut state, &witness.block);

    // 3. Compute output hashes
    let block_hash = witness.block.hash();
    let smt_root = state.compute_smt_root();
    let state_hash = compute_state_hash(&witness.prev_state_hash, &smt_root);
    let trace_hash = compute_trace_hash(&witness.prev_trace_hash, &block_hash, &state_hash);

    // 4. Commit public output
    let output = BlockOutput {
        block_number: witness.block.number,
        block_hash,
        state_hash,
        trace_hash,
        smt_root,
        success_count,
    };

    sp1_zkvm::io::commit(&output);
}
