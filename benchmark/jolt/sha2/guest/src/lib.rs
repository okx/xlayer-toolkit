#![cfg_attr(feature = "guest", no_std)]

extern crate alloc;
use alloc::vec::Vec;

// NOTE: We use raw `#[cfg(inline)]` instead of `#[cfg(feature = "inline")]` because
// `jolt build` overrides --features and only passes `--features guest`.
// The `inline` cfg flag is set via RUSTFLAGS="--cfg inline" in run.sh build-guest.

#[cfg(inline)]
mod inline {
    extern crate alloc;
    use alloc::vec::Vec;

    /// SHA-256 chain using Jolt inline optimization.
    /// Hashes input of arbitrary size N times.
    #[jolt::provable(heap_size = 65536, max_trace_length = 4194304)]
    fn sha2_chain_inline(input: Vec<u8>, num_iters: u32) -> [u8; 32] {
        let mut hash = jolt_inlines_sha2::Sha256::digest(&input);
        for _ in 1..num_iters {
            hash = jolt_inlines_sha2::Sha256::digest(&hash);
        }
        hash
    }
}
#[cfg(inline)]
pub use inline::*;

#[cfg(not(inline))]
mod native {
    extern crate alloc;
    use alloc::vec::Vec;

    /// SHA-256 chain without inline optimization.
    /// Uses pure Rust SHA-256 compiled to standard RISC-V instructions.
    #[jolt::provable(heap_size = 65536, max_trace_length = 16777216)]
    fn sha2_chain_native(input: Vec<u8>, num_iters: u32) -> [u8; 32] {
        use sha2::Digest;
        let result = sha2::Sha256::digest(&input);
        let mut hash = [0u8; 32];
        hash.copy_from_slice(&result);
        for _ in 1..num_iters {
            let result = sha2::Sha256::digest(&hash);
            hash.copy_from_slice(&result);
        }
        hash
    }
}
#[cfg(not(inline))]
pub use native::*;
