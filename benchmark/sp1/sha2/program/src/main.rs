#![no_main]
sp1_zkvm::entrypoint!(main);

use alloy_sol_types::SolType;
use sha2_lib::{sha2_hash, PublicValuesStruct};

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
