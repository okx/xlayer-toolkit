//! Witness generation for ZK proofs

use anyhow::Result;
use serde::{Deserialize, Serialize};
use xlayer_core::{Block, State, AccountState, Hash, Address};
use xlayer_smt::SmtProof;

/// Witness for block verification
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

/// Witness generator
pub struct WitnessGenerator {
    state: State,
}

impl WitnessGenerator {
    /// Create a new witness generator
    pub fn new(state: State) -> Self {
        Self { state }
    }

    /// Generate witness for a block
    pub fn generate_witness(
        &self,
        block: &Block,
        prev_state_hash: Hash,
        prev_trace_hash: Hash,
    ) -> Result<BlockWitness> {
        // Collect all addresses involved in the block
        let mut addresses: Vec<Address> = Vec::new();
        for tx in &block.transactions {
            if !addresses.contains(&tx.from) {
                addresses.push(tx.from);
            }
            if !addresses.contains(&tx.to) {
                addresses.push(tx.to);
            }
        }

        // Get initial states and proofs
        let mut initial_states = Vec::new();
        let mut smt_proofs = Vec::new();

        for addr in addresses {
            let account = self.state.get_account(&addr);
            initial_states.push((addr, account));

            // Generate SMT proof
            if let Some(proof) = self.state.get_proof(&addr) {
                smt_proofs.push(proof);
            } else {
                // Account doesn't exist yet, generate empty proof
                // In production, handle this case properly
                return Err(anyhow::anyhow!("No SMT proof for address"));
            }
        }

        Ok(BlockWitness {
            block: block.clone(),
            initial_states,
            smt_proofs,
            prev_smt_root: self.state.smt_root(),
            prev_state_hash,
            prev_trace_hash,
        })
    }

    /// Update state after block execution
    pub fn update_state(&mut self, state: State) {
        self.state = state;
    }
}
