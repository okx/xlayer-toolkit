use std::hash::{BuildHasher, Hasher, RandomState};
use alloy_sol_types::sol;

sol! {
    /// The public values encoded as a struct that can be easily deserialized inside Solidity.
    struct PublicValuesStruct {
        uint64 n;
        uint64 a;
        uint64 b;
    }
}

/// Compute the n'th fibonacci number (wrapping around on overflows), using normal Rust code.
pub fn fibonacci(n: u64) -> (u64, u64) {
    tokio::runtime::Builder::new_current_thread()
        .build()
        .unwrap()
        .block_on(fibonacci_async(n))
}

pub async fn fibonacci_async(n: u64) -> (u64, u64) {

    let hasher = RandomState::new().build_hasher();

    // Get the seed
    let r = hasher.finish();

    println!("rand_state: {}", r);


    let mut a = 0u64;
    let mut b = 1u64;
    for _ in 0..n {
        let c = a.wrapping_add(b);
        a = b;
        b = c;
    }
    (a, b)
}
