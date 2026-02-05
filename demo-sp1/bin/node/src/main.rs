//! ZK Bisection L2 Node
//!
//! A minimal L2 node that:
//! - Produces blocks every 2 seconds
//! - Maintains state with SMT
//! - Computes trace_hash per block
//! - Provides RPC endpoints for proposer/challenger

use axum::{
    extract::State as AxumState,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::sync::{Arc, RwLock};
use std::time::Duration;
use tokio::time::interval;
use tracing::{info, Level};
use tracing_subscriber::FmtSubscriber;
use xlayer_core::{
    Block, BlockExecutor, Hash, State as L2State, Transaction, TxType,
};

/// Node configuration
#[derive(Clone)]
struct Config {
    block_time: Duration,
    rpc_addr: String,
    batch_size: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            block_time: Duration::from_secs(2),
            rpc_addr: "0.0.0.0:8546".to_string(),
            batch_size: 100,
        }
    }
}

/// Block info for storage
#[derive(Clone, Serialize)]
struct BlockInfo {
    number: u64,
    hash: Hash,
    parent_hash: Hash,
    state_hash: Hash,
    trace_hash: Hash,
    timestamp: u64,
    tx_count: u32,
}

/// Shared node state
struct NodeState {
    /// Current L2 state
    state: L2State,
    /// Latest block info
    latest_block: BlockInfo,
    /// Block history (for queries)
    blocks: Vec<BlockInfo>,
    /// Current batch blocks
    batch_blocks: Vec<BlockInfo>,
    /// Completed batches
    batches: Vec<Batch>,
    /// Previous state hash (for incremental hash)
    prev_state_hash: Hash,
    /// Previous trace hash
    prev_trace_hash: Hash,
}

#[derive(Clone, Serialize)]
struct Batch {
    index: u64,
    start_block: u64,
    end_block: u64,
    state_root: Hash,
    trace_hash: Hash,
}

impl NodeState {
    fn new() -> Self {
        let state = L2State::new();
        let genesis = BlockInfo {
            number: 0,
            hash: [0u8; 32],
            parent_hash: [0u8; 32],
            state_hash: state.smt_root(),
            trace_hash: [0u8; 32],
            timestamp: 0,
            tx_count: 0,
        };

        Self {
            state,
            latest_block: genesis.clone(),
            blocks: vec![genesis],
            batch_blocks: vec![],
            batches: vec![],
            prev_state_hash: [0u8; 32],
            prev_trace_hash: [0u8; 32],
        }
    }
}

type SharedState = Arc<RwLock<NodeState>>;

#[tokio::main]
async fn main() {
    // Initialize logging
    let subscriber = FmtSubscriber::builder()
        .with_max_level(Level::INFO)
        .finish();
    tracing::subscriber::set_global_default(subscriber).expect("setting default subscriber failed");

    info!("Starting ZK Bisection L2 Node...");

    let config = Config::default();
    let state = Arc::new(RwLock::new(NodeState::new()));

    // Start block production
    let block_state = state.clone();
    let block_time = config.block_time;
    let batch_size = config.batch_size;
    tokio::spawn(async move {
        block_production_loop(block_state, block_time, batch_size).await;
    });

    // Start RPC server
    let app = Router::new()
        .route("/", get(health))
        .route("/health", get(health))
        .route("/", post(rpc_handler))
        .with_state(state);

    info!("RPC server listening on {}", config.rpc_addr);
    let listener = tokio::net::TcpListener::bind(&config.rpc_addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

/// Block production loop - produces blocks every block_time
async fn block_production_loop(state: SharedState, block_time: Duration, batch_size: u64) {
    let mut ticker = interval(block_time);

    loop {
        ticker.tick().await;

        let mut node_state = state.write().unwrap();

        // Create mock transactions for demo
        let txs = create_mock_transactions(node_state.latest_block.number + 1);

        // Create block
        let block = Block::new(
            node_state.latest_block.number + 1,
            node_state.latest_block.hash,
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs(),
        );

        // Create executor
        let mut executor = BlockExecutor::new(
            node_state.state.clone(),
            node_state.prev_state_hash,
            node_state.prev_trace_hash,
        );

        // Create block with transactions
        let mut block_with_txs = block;
        for tx in txs {
            block_with_txs.add_transaction(tx);
        }

        // Execute block
        let result = executor.execute_block(&block_with_txs);

        // Create block info
        let block_info = BlockInfo {
            number: block_with_txs.number,
            hash: block_with_txs.hash(),
            parent_hash: block_with_txs.parent_hash,
            state_hash: result.state_hash,
            trace_hash: result.trace_hash,
            timestamp: block_with_txs.timestamp,
            tx_count: result.tx_count,
        };

        info!(
            "Block {} produced: state_hash={}, trace_hash={}, txs={}/{}",
            block_info.number,
            hex::encode(&block_info.state_hash[..4]),
            hex::encode(&block_info.trace_hash[..4]),
            result.success_count,
            result.tx_count
        );

        // Update state
        node_state.state = executor.state().clone();
        node_state.prev_state_hash = result.state_hash;
        node_state.prev_trace_hash = result.trace_hash;
        node_state.latest_block = block_info.clone();
        node_state.blocks.push(block_info.clone());
        node_state.batch_blocks.push(block_info.clone());

        // Check if batch is complete
        if node_state.batch_blocks.len() as u64 >= batch_size {
            let batch = Batch {
                index: node_state.batches.len() as u64,
                start_block: node_state.batch_blocks.first().unwrap().number,
                end_block: node_state.batch_blocks.last().unwrap().number,
                state_root: node_state.prev_state_hash,
                trace_hash: node_state.prev_trace_hash,
            };

            info!(
                "Batch {} complete: blocks {}-{}, state_root={}",
                batch.index,
                batch.start_block,
                batch.end_block,
                hex::encode(&batch.state_root[..4])
            );

            node_state.batches.push(batch);
            node_state.batch_blocks.clear();
        }
    }
}

/// Create mock transactions for demo
fn create_mock_transactions(block_num: u64) -> Vec<Transaction> {
    // Create 10 transfers per block
    (0u64..10)
        .map(|i| {
            let mut from = [0u8; 32];
            let mut to = [0u8; 32];
            from[0] = (block_num % 256) as u8;
            from[1] = i as u8;
            to[0] = ((block_num + 1) % 256) as u8;
            to[1] = i as u8;

            Transaction {
                tx_type: TxType::Transfer,
                from,
                to,
                amount: 100 + (i as u128 * 10),
                nonce: block_num * 10 + i,
            }
        })
        .collect()
}

/// Health check endpoint
async fn health() -> &'static str {
    "ok"
}

/// JSON-RPC request
#[derive(Deserialize)]
struct RpcRequest {
    #[serde(default)]
    jsonrpc: String,
    method: String,
    #[serde(default)]
    params: Option<serde_json::Value>,
    #[serde(default)]
    id: serde_json::Value,
}

/// JSON-RPC response
#[derive(Serialize)]
struct RpcResponse {
    jsonrpc: String,
    result: serde_json::Value,
    id: serde_json::Value,
}

/// RPC handler
async fn rpc_handler(
    AxumState(state): AxumState<SharedState>,
    Json(req): Json<RpcRequest>,
) -> Json<RpcResponse> {
    let node_state = state.read().unwrap();

    let result = match req.method.as_str() {
        "eth_blockNumber" | "x2_blockNumber" => {
            serde_json::json!(format!("0x{:x}", node_state.latest_block.number))
        }
        "eth_getBlockByNumber" | "x2_getBlockByNumber" => {
            let block = &node_state.latest_block;
            serde_json::json!({
                "number": format!("0x{:x}", block.number),
                "hash": format!("0x{}", hex::encode(block.hash)),
                "stateRoot": format!("0x{}", hex::encode(block.state_hash)),
                "traceHash": format!("0x{}", hex::encode(block.trace_hash)),
                "timestamp": format!("0x{:x}", block.timestamp),
                "transactions": block.tx_count
            })
        }
        "x2_getBlock" => {
            // Get block by number from params
            let block_num = req.params.as_ref()
                .and_then(|p| p.as_array())
                .and_then(|arr| arr.first())
                .and_then(|v| v.as_u64())
                .unwrap_or(node_state.latest_block.number);
            
            if let Some(block) = node_state.blocks.iter().find(|b| b.number == block_num) {
                serde_json::json!({
                    "number": block.number,
                    "hash": format!("0x{}", hex::encode(block.hash)),
                    "parentHash": format!("0x{}", hex::encode(block.parent_hash)),
                    "stateHash": format!("0x{}", hex::encode(block.state_hash)),
                    "traceHash": format!("0x{}", hex::encode(block.trace_hash)),
                    "timestamp": block.timestamp,
                    "txCount": block.tx_count
                })
            } else {
                serde_json::json!(null)
            }
        }
        "x2_getLatestBatch" => {
            if let Some(batch) = node_state.batches.last() {
                serde_json::json!({
                    "index": batch.index,
                    "startBlock": batch.start_block,
                    "endBlock": batch.end_block,
                    "stateRoot": format!("0x{}", hex::encode(batch.state_root)),
                    "traceHash": format!("0x{}", hex::encode(batch.trace_hash))
                })
            } else {
                serde_json::json!(null)
            }
        }
        "x2_getBatch" => {
            // Get batch by index from params
            let batch_idx = req.params.as_ref()
                .and_then(|p| p.as_array())
                .and_then(|arr| arr.first())
                .and_then(|v| v.as_u64());
            
            if let Some(idx) = batch_idx {
                if let Some(batch) = node_state.batches.iter().find(|b| b.index == idx) {
                    serde_json::json!({
                        "index": batch.index,
                        "startBlock": batch.start_block,
                        "endBlock": batch.end_block,
                        "stateRoot": format!("0x{}", hex::encode(batch.state_root)),
                        "traceHash": format!("0x{}", hex::encode(batch.trace_hash))
                    })
                } else {
                    serde_json::json!(null)
                }
            } else {
                serde_json::json!(null)
            }
        }
        "x2_getBatchCount" => {
            serde_json::json!(node_state.batches.len())
        }
        "x2_getBlockRange" => {
            // Get blocks in range for bisection
            let params = req.params.as_ref().and_then(|p| p.as_array());
            if let Some(arr) = params {
                let start = arr.get(0).and_then(|v| v.as_u64()).unwrap_or(0);
                let end = arr.get(1).and_then(|v| v.as_u64()).unwrap_or(node_state.latest_block.number);
                
                let blocks: Vec<_> = node_state.blocks.iter()
                    .filter(|b| b.number >= start && b.number <= end)
                    .map(|b| serde_json::json!({
                        "number": b.number,
                        "traceHash": format!("0x{}", hex::encode(b.trace_hash)),
                        "stateHash": format!("0x{}", hex::encode(b.state_hash))
                    }))
                    .collect();
                serde_json::json!(blocks)
            } else {
                serde_json::json!([])
            }
        }
        _ => serde_json::json!(null),
    };

    Json(RpcResponse {
        jsonrpc: "2.0".to_string(),
        result,
        id: req.id,
    })
}
