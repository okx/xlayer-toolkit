//! Multi-threaded parallel computation test for Jolt + ZeroOS
//!
//! Tests whether Jolt zkVM with ZeroOS supports std::thread
//!
//! Task: 4 threads compute partial sums of 1+2+...+n in parallel, then aggregate
//! Result: Always deterministic (n*(n+1)/2)
//! Note: Thread scheduling in ZeroOS is cooperative and deterministic

use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};
use std::thread;

/// Result of multi-threaded computation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ComputeResult {
    /// Input n
    pub n: u64,
    /// Computed sum
    pub total: u64,
    /// Expected sum (n*(n+1)/2)
    pub expected: u64,
    /// Whether result is correct
    pub is_correct: bool,
    /// Thread completion order (deterministic in ZeroOS)
    pub completion_order: Vec<u64>,
}

/// Compute 1+2+...+n using 4 parallel threads
///
/// This function is marked with `#[jolt::provable]` to make it provable
/// inside the Jolt zkVM. It uses std::thread for parallel computation,
/// which is handled by ZeroOS's cooperative scheduler.
#[jolt::provable(
    max_input_size = 1024,
    max_output_size = 1024,
    memory_size = 16777216,    // 16MB memory
    stack_size = 131072,       // 128KB stack
    max_trace_length = 16777216
)]
pub fn compute_sum(n: u64) -> ComputeResult {
    println!("Computing 1+2+...+{} using 4 threads (ZeroOS)", n);

    // Track thread completion order (deterministic in ZeroOS)
    let completion_order = Arc::new(Mutex::new(Vec::new()));

    // Divide computation into 4 chunks
    let chunk_size = n / 4;
    let mut handles = vec![];

    for thread_id in 0..4u64 {
        let order = Arc::clone(&completion_order);

        let start = thread_id * chunk_size + 1;
        let end = if thread_id == 3 {
            n
        } else {
            (thread_id + 1) * chunk_size
        };

        // std::thread::spawn works via ZeroOS scheduler
        let handle = thread::spawn(move || {
            // Compute partial sum for this thread's range
            let partial_sum: u64 = (start..=end).sum();

            println!(
                "Thread {} completed: computed {}..{} = {}",
                thread_id, start, end, partial_sum
            );

            // Record completion order
            order.lock().unwrap().push(thread_id);

            partial_sum
        });

        handles.push(handle);
    }

    // Wait for all threads and aggregate results
    let mut total: u64 = 0;
    for handle in handles {
        total += handle.join().unwrap();
    }

    // Get completion order (deterministic in ZeroOS!)
    let order = completion_order.lock().unwrap().clone();
    println!("Thread completion order: {:?}", order);

    // Verify result
    let expected = n * (n + 1) / 2;
    let is_correct = total == expected;

    println!("Computed result: {}", total);
    println!("Expected result: {}", expected);
    println!("Result correct: {}", is_correct);

    ComputeResult {
        n,
        total,
        expected,
        is_correct,
        completion_order: order,
    }
}
