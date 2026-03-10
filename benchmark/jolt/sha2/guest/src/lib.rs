#![cfg_attr(feature = "guest", no_std)]

/// SHA-256 chain using Jolt inline optimization.
/// Iteratively hashes a 32-byte input N times.
#[jolt::provable(heap_size = 32768, max_trace_length = 4194304)]
fn sha2_chain_inline(input: [u8; 32], num_iters: u32) -> [u8; 32] {
    let mut hash = input;
    for _ in 0..num_iters {
        hash = jolt_inlines_sha2::Sha256::digest(&hash);
    }
    hash
}

/// SHA-256 chain without inline optimization.
/// Uses pure Rust SHA-256 compiled to standard RISC-V instructions.
#[jolt::provable(heap_size = 65536, max_trace_length = 16777216)]
fn sha2_chain_native(input: [u8; 32], num_iters: u32) -> [u8; 32] {
    use sha2::Digest;
    let mut hash = input;
    for _ in 0..num_iters {
        let result = sha2::Sha256::digest(&hash);
        hash.copy_from_slice(&result);
    }
    hash
}
