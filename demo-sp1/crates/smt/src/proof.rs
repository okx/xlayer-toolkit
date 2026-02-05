//! SMT proof generation and verification

use serde::{Deserialize, Serialize};
use crate::{hasher::Keccak256Hasher, TREE_DEPTH};

/// SMT inclusion proof
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SmtProof {
    /// The key being proven
    pub key: [u8; 32],
    /// The value at the key
    pub value: [u8; 32],
    /// Sibling hashes from leaf to root (256 elements)
    pub siblings: Vec<[u8; 32]>,
}

impl SmtProof {
    /// Verify this proof against a root hash
    pub fn verify(&self, root: &[u8; 32], key: &[u8; 32], value: &[u8; 32]) -> bool {
        if self.key != *key || self.value != *value {
            return false;
        }
        
        if self.siblings.len() != TREE_DEPTH {
            return false;
        }

        let computed_root = self.compute_root();
        computed_root == *root
    }

    /// Compute root from proof
    pub fn compute_root(&self) -> [u8; 32] {
        let mut current_hash = Keccak256Hasher::hash_leaf(&self.key, &self.value);
        let path = Self::key_to_path(&self.key);

        for (i, sibling) in self.siblings.iter().enumerate() {
            let depth = TREE_DEPTH - 1 - i;
            let is_right = path[depth];
            
            let (left, right) = if is_right {
                (*sibling, current_hash)
            } else {
                (current_hash, *sibling)
            };
            
            current_hash = Keccak256Hasher::hash_pair(&left, &right);
        }

        current_hash
    }

    /// Convert key to path
    fn key_to_path(key: &[u8; 32]) -> Vec<bool> {
        let mut path = Vec::with_capacity(TREE_DEPTH);
        for byte in key {
            for i in (0..8).rev() {
                path.push((byte >> i) & 1 == 1);
            }
        }
        path
    }
}

/// Trait for SMT proof verification (used in zkVM)
pub trait SmtProofVerifier {
    fn verify_proof(
        root: &[u8; 32],
        key: &[u8; 32],
        value: &[u8; 32],
        proof: &SmtProof,
    ) -> bool;
}

impl SmtProofVerifier for SmtProof {
    fn verify_proof(
        root: &[u8; 32],
        key: &[u8; 32],
        value: &[u8; 32],
        proof: &SmtProof,
    ) -> bool {
        proof.verify(root, key, value)
    }
}
