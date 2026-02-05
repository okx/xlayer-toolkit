//! Multi-threaded parallel computation test
//!
//! Tests whether SP1 zkVM supports std::thread
//!
//! Task: 4 threads compute partial sums of 1+2+...+n in parallel, then aggregate
//! Result: Always deterministic (n*(n+1)/2)
//! Process: Thread completion order is non-deterministic

#![no_main]
sp1_zkvm::entrypoint!(main);

use std::thread;
use std::sync::{Arc, Mutex};

pub fn main() {
    // Read input
    let n: u64 = sp1_zkvm::io::read::<u64>();
    
    println!("Computing 1+2+...+{} using 4 threads", n);
    
    // Collect the completion order of each thread
    let completion_order = Arc::new(Mutex::new(Vec::new()));
    
    // Divide the computation into 4 chunks
    let chunk_size = n / 4;
    let mut handles = vec![];
    
    for thread_id in 0..4u64 {
        let order = Arc::clone(&completion_order);
        
        let start = thread_id * chunk_size + 1;
        let end = if thread_id == 3 { n } else { (thread_id + 1) * chunk_size };
        
        let handle = thread::spawn(move || {
            // Compute the partial sum for this thread's range
            let partial_sum: u64 = (start..=end).sum();
            
            println!("Thread {} completed: computed {}..{} = {}", thread_id, start, end, partial_sum);
            
            // Record completion order
            order.lock().unwrap().push(thread_id);
            
            partial_sum
        });
        
        handles.push(handle);
    }
    
    // Wait for all threads to complete and aggregate results
    let mut total: u64 = 0;
    for handle in handles {
        total += handle.join().unwrap();
    }
    
    // Get completion order
    let order = completion_order.lock().unwrap();
    println!("Thread completion order: {:?}", *order);
    
    // Expected result
    let expected = n * (n + 1) / 2;
    let is_correct = total == expected;
    
    println!("Computed result: {}", total);
    println!("Expected result: {}", expected);
    println!("Result correct: {}", is_correct);
    
    // Commit output
    sp1_zkvm::io::commit(&total);
    sp1_zkvm::io::commit(&is_correct);
}
