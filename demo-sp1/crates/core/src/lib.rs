//! xlayer-dex core business logic
//!
//! This crate contains the core execution logic that is shared between:
//! - The host (proposer/challenger)
//! - The SP1 zkVM program

pub mod types;
pub mod block;
pub mod tx;
pub mod state;
pub mod dex;
pub mod executor;
pub mod trace;

pub use types::*;
pub use block::{Block, BlockHeader};
pub use tx::{Transaction, TxType};
pub use state::State;
pub use executor::BlockExecutor;
pub use trace::{TraceHash, TraceLog, TraceEntry};
