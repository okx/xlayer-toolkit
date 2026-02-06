//! Transaction tracing: log transaction/block lifecycle to a file.
//! Logging is non-blocking (bounded channel + writer thread).

pub mod tracer;
pub mod transaction;
pub mod utils;
