#![no_main]
sp1_zkvm::entrypoint!(main);

use alloy_sol_types::{sol, SolType};

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

fn sha2_hash(variant: u32, input: &[u8]) -> [u8; 32] {
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

pub fn main() {
    let variant = sp1_zkvm::io::read::<u32>();
    let input = sp1_zkvm::io::read::<Vec<u8>>();

    let digest = sha2_hash(variant, &input);

    let bytes = PublicValuesStruct::abi_encode(&PublicValuesStruct {
        variant,
        digest: digest.into(),
    });
    sp1_zkvm::io::commit_slice(&bytes);
}
