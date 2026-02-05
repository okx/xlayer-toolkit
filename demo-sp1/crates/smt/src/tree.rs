//! Sparse Merkle Tree implementation

use std::collections::HashMap;
use crate::{hasher::Keccak256Hasher, proof::SmtProof, EMPTY_HASH, TREE_DEPTH};

/// Sparse Merkle Tree with 256-level depth
#[derive(Clone, Debug)]
pub struct SparseMerkleTree {
    /// Leaf nodes: key -> value
    leaves: HashMap<[u8; 32], [u8; 32]>,
    /// Cached intermediate nodes: (depth, path_prefix) -> hash
    nodes: HashMap<(usize, Vec<u8>), [u8; 32]>,
    /// Root hash
    root: [u8; 32],
}

impl SparseMerkleTree {
    /// Create a new empty SMT
    pub fn new() -> Self {
        Self {
            leaves: HashMap::new(),
            nodes: HashMap::new(),
            root: EMPTY_HASH,
        }
    }

    /// Get the root hash
    pub fn root(&self) -> [u8; 32] {
        self.root
    }

    /// Insert a key-value pair
    pub fn insert(&mut self, key: [u8; 32], value: [u8; 32]) {
        self.leaves.insert(key, value);
        self.recompute_root();
    }

    /// Batch insert multiple key-value pairs
    pub fn batch_insert(&mut self, entries: Vec<([u8; 32], [u8; 32])>) {
        for (key, value) in entries {
            self.leaves.insert(key, value);
        }
        self.recompute_root();
    }

    /// Get value by key
    pub fn get(&self, key: &[u8; 32]) -> Option<[u8; 32]> {
        self.leaves.get(key).copied()
    }

    /// Generate a proof for a key
    pub fn get_proof(&self, key: &[u8; 32]) -> Option<SmtProof> {
        let value = self.leaves.get(key)?;
        let mut siblings = Vec::with_capacity(TREE_DEPTH);
        
        // Walk from leaf to root, collecting sibling hashes
        let path = Self::key_to_path(key);
        
        for depth in (0..TREE_DEPTH).rev() {
            let sibling_path = Self::get_sibling_path(&path, depth);
            let sibling_hash = self.get_node_hash(depth, &sibling_path);
            siblings.push(sibling_hash);
        }

        Some(SmtProof {
            key: *key,
            value: *value,
            siblings,
        })
    }

    /// Recompute the root hash from all leaves
    fn recompute_root(&mut self) {
        self.nodes.clear();
        
        if self.leaves.is_empty() {
            self.root = EMPTY_HASH;
            return;
        }

        // Collect leaf data first to avoid borrow conflict
        let leaf_data: Vec<_> = self.leaves
            .iter()
            .map(|(key, value)| {
                let leaf_hash = Keccak256Hasher::hash_leaf(key, value);
                let path = Self::key_to_path(key);
                (path, leaf_hash)
            })
            .collect();

        // Propagate all leaves up
        for (path, leaf_hash) in leaf_data {
            self.propagate_up(&path, leaf_hash);
        }

        // Get root from depth 0
        self.root = self.get_node_hash(0, &[]);
    }

    /// Propagate a leaf hash up to the root
    fn propagate_up(&mut self, path: &[bool], leaf_hash: [u8; 32]) {
        let mut current_hash = leaf_hash;
        
        for depth in (0..TREE_DEPTH).rev() {
            let path_prefix: Vec<u8> = path[..depth].iter().map(|&b| if b { 1 } else { 0 }).collect();
            let is_right = path[depth];
            
            // Get sibling hash
            let sibling_path = Self::get_sibling_path_from_bits(path, depth);
            let sibling_hash = self.nodes.get(&(depth + 1, sibling_path.clone()))
                .copied()
                .unwrap_or(Self::get_default_hash(depth + 1));

            // Compute parent hash
            let (left, right) = if is_right {
                (sibling_hash, current_hash)
            } else {
                (current_hash, sibling_hash)
            };
            
            current_hash = Keccak256Hasher::hash_pair(&left, &right);
            self.nodes.insert((depth, path_prefix), current_hash);
        }
    }

    /// Get node hash at a specific depth and path
    fn get_node_hash(&self, depth: usize, path_prefix: &[u8]) -> [u8; 32] {
        self.nodes.get(&(depth, path_prefix.to_vec()))
            .copied()
            .unwrap_or(Self::get_default_hash(depth))
    }

    /// Get default hash for empty subtree at given depth
    fn get_default_hash(_depth: usize) -> [u8; 32] {
        // For simplicity, use EMPTY_HASH for all empty nodes
        // In production, precompute default hashes for each depth
        EMPTY_HASH
    }

    /// Convert key to path (array of bits)
    fn key_to_path(key: &[u8; 32]) -> Vec<bool> {
        let mut path = Vec::with_capacity(TREE_DEPTH);
        for byte in key {
            for i in (0..8).rev() {
                path.push((byte >> i) & 1 == 1);
            }
        }
        path
    }

    /// Get sibling path at given depth
    fn get_sibling_path(path: &[bool], depth: usize) -> Vec<u8> {
        let mut sibling_path: Vec<u8> = path[..depth].iter().map(|&b| if b { 1 } else { 0 }).collect();
        if depth < path.len() {
            sibling_path.push(if path[depth] { 0 } else { 1 });
        }
        sibling_path
    }

    fn get_sibling_path_from_bits(path: &[bool], depth: usize) -> Vec<u8> {
        let mut result: Vec<u8> = path[..depth].iter().map(|&b| if b { 1 } else { 0 }).collect();
        if depth < path.len() {
            result.push(if path[depth] { 0 } else { 1 });
        }
        result
    }
}

impl Default for SparseMerkleTree {
    fn default() -> Self {
        Self::new()
    }
}
