use alloy_sol_types::sol;

#[cfg(feature = "precompile")]
use sha2_precompile as sha2_impl;
#[cfg(not(feature = "precompile"))]
use sha2 as sha2_impl;

use sha2_impl::{Digest, Sha224, Sha256, Sha384, Sha512};

sol! {
    struct PublicValuesStruct {
        uint32 variant;
        bytes32 digest;
    }
}

/// Compute the SHA-2 hash for the given variant (224, 256, 384, 512).
/// Returns the first 32 bytes of the digest (full for SHA-256, truncated for SHA-512).
pub fn sha2_hash(variant: u32, input: &[u8]) -> [u8; 32] {
    let mut result = [0u8; 32];
    match variant {
        224 => {
            let hash = Sha224::digest(input);
            result[..28].copy_from_slice(&hash);
        }
        256 => {
            let hash = Sha256::digest(input);
            result.copy_from_slice(&hash);
        }
        384 => {
            let hash = Sha384::digest(input);
            result.copy_from_slice(&hash[..32]);
        }
        512 => {
            let hash = Sha512::digest(input);
            result.copy_from_slice(&hash[..32]);
        }
        _ => panic!("unsupported SHA-2 variant: {}", variant),
    }
    result
}
