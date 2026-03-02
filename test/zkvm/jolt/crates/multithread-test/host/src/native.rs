//! Native (non-zkVM) runner for multi-threaded computation
//!
//! Calls the same guest function directly on the host without zkVM
//! compilation or proof generation. Thread scheduling here uses the
//! real OS scheduler (non-deterministic order), unlike ZeroOS inside
//! the zkVM (deterministic cooperative scheduler).

fn main() {
    let n: u64 = 100;
    println!("Native run: Computing 1+2+...+{} using 4 threads", n);
    println!("Expected: {}\n", n * (n + 1) / 2);

    let result = guest::compute_sum(n);

    println!("\nThread completion order: {:?}", result.completion_order);
    println!(
        "Computed: {}, Expected: {}, Correct: {}",
        result.total, result.expected, result.is_correct
    );

    if result.is_correct {
        println!("\n✅ Native computation successful!");
    } else {
        println!("\n❌ Computation incorrect!");
    }
}
