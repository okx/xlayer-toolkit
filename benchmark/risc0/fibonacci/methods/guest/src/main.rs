risc0_zkvm::guest::entry!(main);

use fibonacci_core::{fibonacci, FibonacciOutput};

fn main() {
    let n: u32 = risc0_zkvm::guest::env::read();
    let (a, b) = fibonacci(n);
    risc0_zkvm::guest::env::commit(&FibonacciOutput { n, a, b });
}
