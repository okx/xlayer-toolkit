/// 32-byte hash (equivalent to B256)
pub type Hash32 = [u8; 32];

/// Format a 32-byte hash as hexadecimal string with 0x prefix
pub fn format_hash_hex(hash: &Hash32) -> String {
    format!("0x{}", hex::encode(hash))
}

/// Convert from B256 (alloy-primitives) or any 32-byte array to Hash32
///
/// This is a convenience function for converting from `alloy_primitives::B256` to `Hash32`.
/// Since B256 implements `AsRef<[u8; 32]>`, this conversion is zero-cost (just a reference copy).
///
/// # Example
///
/// ```rust
/// use xlayer_trace_monitor::{Hash32, from_b256};
///
/// // For [u8; 32], you can use it directly
/// let hash_array: Hash32 = [0x12; 32];
///
/// // If you use alloy_primitives::B256, convert like this:
/// # #[cfg(feature = "alloy")]
/// # {
/// # use alloy_primitives::B256;
/// # let b256_hash: B256 = B256::ZERO;
/// let hash32: Hash32 = from_b256(&b256_hash);
/// # }
/// ```
pub fn from_b256(b256: impl AsRef<[u8; 32]>) -> Hash32 {
    *b256.as_ref()
}
