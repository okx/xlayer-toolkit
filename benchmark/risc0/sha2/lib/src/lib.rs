use sha2::{Digest, Sha224, Sha256, Sha384, Sha512};

/// Compute the SHA-2 hash for the given variant (224, 256, 384, 512).
/// Returns the first 32 bytes of the digest (full for SHA-256, truncated/padded for others).
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
