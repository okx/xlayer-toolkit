//! Sparse Merkle Tree (SMT) implementation for xlayer-dex
//!
//! This module provides a fixed-depth (256-level) SMT for state commitment.
//! Key features:
//! - Fixed depth: Direct address → path mapping
//! - Parallel update friendly: Independent paths
//! - ZK friendly: Simple structure

mod tree;
mod proof;
mod hasher;

pub use tree::SparseMerkleTree;
pub use proof::{SmtProof, SmtProofVerifier};
pub use hasher::Keccak256Hasher;

/// Default empty node hash (keccak256 of empty bytes)
pub const EMPTY_HASH: [u8; 32] = [
    0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c,
    0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
    0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b,
    0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
];

/// SMT tree depth (256 bits for address)
pub const TREE_DEPTH: usize = 256;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_empty_tree() {
        let tree = SparseMerkleTree::new();
        assert_eq!(tree.root(), EMPTY_HASH);
    }

    #[test]
    fn test_insert_and_proof() {
        let mut tree = SparseMerkleTree::new();
        
        let key = [1u8; 32];
        let value = [2u8; 32];
        
        tree.insert(key, value);
        
        let proof = tree.get_proof(&key).unwrap();
        assert!(proof.verify(&tree.root(), &key, &value));
    }
}
