#![no_main]
#![no_std]

extern crate alloc;
use alloc::vec::Vec;

use sha2::{Digest, Sha224, Sha256, Sha384, Sha512};

risc0_zkvm::guest::entry!(main);

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
        _ => panic!("unsupported SHA-2 variant"),
    }
    result
}

fn main() {
    let variant: u32 = risc0_zkvm::guest::env::read();
    let input: Vec<u8> = risc0_zkvm::guest::env::read();
    let digest = sha2_hash(variant, &input);
    risc0_zkvm::guest::env::commit(&(variant, digest));
}
