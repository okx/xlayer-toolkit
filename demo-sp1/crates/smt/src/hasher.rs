//! Keccak256 hasher for SMT

use tiny_keccak::{Hasher, Keccak};

/// Keccak256 hasher
pub struct Keccak256Hasher;

impl Keccak256Hasher {
    /// Hash two 32-byte values together
    pub fn hash_pair(left: &[u8; 32], right: &[u8; 32]) -> [u8; 32] {
        let mut hasher = Keccak::v256();
        hasher.update(left);
        hasher.update(right);
        let mut output = [0u8; 32];
        hasher.finalize(&mut output);
        output
    }

    /// Hash a single value
    pub fn hash(data: &[u8]) -> [u8; 32] {
        let mut hasher = Keccak::v256();
        hasher.update(data);
        let mut output = [0u8; 32];
        hasher.finalize(&mut output);
        output
    }

    /// Hash a key-value pair for leaf node
    pub fn hash_leaf(key: &[u8; 32], value: &[u8; 32]) -> [u8; 32] {
        let mut hasher = Keccak::v256();
        hasher.update(&[0x00]); // Leaf prefix
        hasher.update(key);
        hasher.update(value);
        let mut output = [0u8; 32];
        hasher.finalize(&mut output);
        output
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hash_pair() {
        let left = [1u8; 32];
        let right = [2u8; 32];
        let hash = Keccak256Hasher::hash_pair(&left, &right);
        assert_ne!(hash, [0u8; 32]);
    }
}
