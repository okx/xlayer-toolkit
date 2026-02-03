#![no_std]
#![cfg_attr(any(target_arch = "mips64", target_arch = "riscv64"), no_main)]

extern crate alloc;

use alloc::string::String;
use kona_std_fpvm_proc::client_entry;

/// Convert u64 to string
fn u64_to_string(mut n: u64) -> String {
    if n == 0 {
        return String::from("0");
    }

    let mut digits = alloc::vec::Vec::new();
    while n > 0 {
        digits.push((b'0' + (n % 10) as u8) as char);
        n /= 10;
    }
    digits.reverse();
    digits.into_iter().collect()
}

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

/// Print a single Fibonacci result
fn print_fib(n: u64, value: u64) {
    kona_std_fpvm::io::print("fib(");
    kona_std_fpvm::io::print(&u64_to_string(n));
    kona_std_fpvm::io::print(") = ");
    kona_std_fpvm::io::print(&u64_to_string(value));
    kona_std_fpvm::io::print("\n");
}

/// Calculate and print Fibonacci sequence
fn calculate_fibonacci_sequence(count: u64) {
    kona_std_fpvm::io::print("=== Fibonacci Sequence Calculator ===\n");
    kona_std_fpvm::io::print("Calculating first ");
    kona_std_fpvm::io::print(&u64_to_string(count));
    kona_std_fpvm::io::print(" Fibonacci numbers:\n\n");

    for i in 0..count {
        let fib = fibonacci(i);
        print_fib(i, fib);
    }

    kona_std_fpvm::io::print("\n=== Calculation Complete ===\n");
}

#[client_entry]
fn main() -> Result<(), String> {
    // Calculate first 20 Fibonacci numbers
    calculate_fibonacci_sequence(20);

    // Test some large numbers
    kona_std_fpvm::io::print("\n=== Testing Large Numbers ===\n");
    let test_values = [30, 40, 50, 60, 70, 80, 90];

    for &n in &test_values {
        let fib = fibonacci(n);
        print_fib(n, fib);
    }

    kona_std_fpvm::io::print("\n=== All Tests Passed ===\n");
    Ok::<(), String>(())
}
