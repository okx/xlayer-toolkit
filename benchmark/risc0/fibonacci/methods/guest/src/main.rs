#![no_main]
#![no_std]

risc0_zkvm::guest::entry!(main);

fn fibonacci(n: u32) -> (u32, u32) {
    let mut a = 0u32;
    let mut b = 1u32;
    for _ in 0..n {
        let c = a.wrapping_add(b);
        a = b;
        b = c;
    }
    (a, b)
}

fn main() {
    let n: u32 = risc0_zkvm::guest::env::read();
    let (a, b) = fibonacci(n);
    risc0_zkvm::guest::env::commit(&(n, a, b));
}
