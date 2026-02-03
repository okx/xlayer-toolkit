#![no_std]
#![cfg_attr(any(target_arch = "mips64", target_arch = "riscv64"), no_main)]

extern crate alloc;

use alloc::{format, string::String, vec::Vec};
use kona_std_fpvm_proc::client_entry;

/// Calculate the nth Fibonacci number
fn fibonacci(n: u64) -> u64 {
    if n <= 1 {
        return n;
    }

    let mut a = 0u64;
    let mut b = 1u64;

    for _ in 2..=n {
        let temp = a.wrapping_add(b);
        a = b;
        b = temp;
    }

    b
}

/// Print an array of u64 values
fn print_array(arr: &[u64]) {
    kona_std_fpvm::io::print("[");
    for (i, &value) in arr.iter().enumerate() {
        if i > 0 {
            kona_std_fpvm::io::print(", ");
        }
        kona_std_fpvm::io::print(&format!("{}", value));
    }
    kona_std_fpvm::io::print("]\n");
}

#[client_entry]
fn main() -> Result<(), String> {
    // Input array
    let input = [0, 1, 2, 3, 4, 5, 10, 20, 30, 40, 50, 60, 70, 80, 90];
    kona_std_fpvm::io::print("Input: ");
    print_array(&input);
    kona_std_fpvm::io::print("\n");

    // Calculate Fibonacci for each input
    let mut output = Vec::new();
    for &n in &input {
        output.push(fibonacci(n));
    }

    // Print output array
    kona_std_fpvm::io::print("Output: ");
    print_array(&output);

    Ok::<(), String>(())
}
