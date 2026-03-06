use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FibonacciOutput {
    pub n: u32,
    pub a: u32,
    pub b: u32,
}

/// Compute the n'th fibonacci number (wrapping around on overflows).
/// Returns (fib(n-1), fib(n)).
pub fn fibonacci(n: u32) -> (u32, u32) {
    let mut a = 0u32;
    let mut b = 1u32;
    for _ in 0..n {
        let c = a.wrapping_add(b);
        a = b;
        b = c;
    }
    (a, b)
}
