//! ZK Bisection L2 Node
//!
//! A minimal L2 node that:
//! - Produces blocks every 2 seconds
//! - Maintains state with SMT
//! - Computes trace_hash per block
//! - Provides RPC endpoints for proposer/challenger
//! - Accepts transactions via x2_sendTransaction (mempool)

use axum::{
    extract::State as AxumState,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::sync::{Arc, RwLock};
use std::time::Duration;
use tokio::time::interval;
use tracing::{info, warn, Level};
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
    max_tx_per_block: usize,
    mempool_size: usize,
}

impl Default for Config {
    fn default() -> Self {
        let max_tx = std::env::var("MAX_TX_PER_BLOCK")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(1000);
        
        Self {
            block_time: Duration::from_secs(2),
            rpc_addr: "0.0.0.0:8546".to_string(),
            batch_size: 100,
            max_tx_per_block: max_tx,
            mempool_size: max_tx * 10, // 10 blocks worth
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

/// Mempool for pending transactions
struct Mempool {
    /// Pending transactions
    pending: VecDeque<Transaction>,
    /// Max size
    max_size: usize,
    /// Stats
    total_received: u64,
    total_included: u64,
}

impl Mempool {
    fn new(max_size: usize) -> Self {
        Self {
            pending: VecDeque::new(),
            max_size,
            total_received: 0,
            total_included: 0,
        }
    }

    fn add(&mut self, tx: Transaction) -> bool {
        if self.pending.len() >= self.max_size {
            return false;
        }
        self.pending.push_back(tx);
        self.total_received += 1;
        true
    }

    fn take(&mut self, count: usize) -> Vec<Transaction> {
        let count = count.min(self.pending.len());
        let txs: Vec<_> = self.pending.drain(..count).collect();
        self.total_included += txs.len() as u64;
        txs
    }

    fn len(&self) -> usize {
        self.pending.len()
    }
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
    /// Transaction mempool
    mempool: Mempool,
    /// Config
    config: Config,
}

#[derive(Clone, Serialize)]
struct Batch {
    index: u64,
    start_block: u64,
    end_block: u64,
    state_root: Hash,
    trace_hash: Hash,
}

/// Treasury address (0x0000...0001)
const TREASURY_ADDRESS: Hash = {
    let mut addr = [0u8; 32];
    addr[31] = 1;
    addr
};

/// Treasury initial balance: 100,000 ETH = 10^22 wei
const TREASURY_BALANCE: u128 = 100_000_000_000_000_000_000_000;

impl NodeState {
    fn new(config: Config) -> Self {
        let mut state = L2State::new();
        
        // Initialize treasury account with 100,000 ETH
        state.set_balance(TREASURY_ADDRESS, TREASURY_BALANCE);
        // Commit SMT updates after initialization
        state.commit_smt_updates();
        info!("Initialized treasury account: 0x{} with {} ETH", 
              hex::encode(&TREASURY_ADDRESS[28..32]), 
              TREASURY_BALANCE / 1_000_000_000_000_000_000);
        
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
            mempool: Mempool::new(config.mempool_size),
            config,
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
    info!("  Max TX per block: {}", config.max_tx_per_block);
    info!("  Mempool size: {}", config.mempool_size);
    
    let rpc_addr = config.rpc_addr.clone();
    let state = Arc::new(RwLock::new(NodeState::new(config)));

    // Start block production
    let block_state = state.clone();
    tokio::spawn(async move {
        block_production_loop(block_state).await;
    });

    // Start RPC server
    let app = Router::new()
        .route("/", get(health))
        .route("/health", get(health))
        .route("/", post(rpc_handler))
        .with_state(state);

    info!("RPC server listening on {}", rpc_addr);
    let listener = tokio::net::TcpListener::bind(&rpc_addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

/// Block production loop - produces blocks every block_time
/// 
/// IMPORTANT: Lock is held minimally to allow concurrent RPC requests
async fn block_production_loop(state: SharedState) {
    // Get config from state
    let (block_time, batch_size, max_tx_per_block) = {
        let node_state = state.read().unwrap();
        (
            node_state.config.block_time,
            node_state.config.batch_size,
            node_state.config.max_tx_per_block,
        )
    };
    
    let mut ticker = interval(block_time);

    loop {
        ticker.tick().await;

        // Phase 1: Acquire lock, get data, release lock quickly
        let (txs, block, current_state, prev_state_hash, prev_trace_hash, mempool_len) = {
            let mut node_state = state.write().unwrap();
            
            // Get transactions from mempool, fallback to mock if empty
            let mempool_len = node_state.mempool.len();
            let txs = if mempool_len > 0 {
                node_state.mempool.take(max_tx_per_block)
            } else {
                // Create mock transactions when no mempool txs
                create_mock_transactions(node_state.latest_block.number + 1)
            };

            // Create block
            let block = Block::new(
                node_state.latest_block.number + 1,
                node_state.latest_block.hash,
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_secs(),
            );

            (
                txs, 
                block, 
                node_state.state.clone(),
                node_state.prev_state_hash,
                node_state.prev_trace_hash,
                mempool_len,
            )
        }; // Lock released here!

        // Phase 2: Execute block WITHOUT holding lock (slow operation)
        let mut executor = BlockExecutor::new(
            current_state,
            prev_state_hash,
            prev_trace_hash,
        );

        let mut block_with_txs = block;
        for tx in txs {
            block_with_txs.add_transaction(tx);
        }

        let result = executor.execute_block(&block_with_txs);

        let block_info = BlockInfo {
            number: block_with_txs.number,
            hash: block_with_txs.hash(),
            parent_hash: block_with_txs.parent_hash,
            state_hash: result.state_hash,
            trace_hash: result.trace_hash,
            timestamp: block_with_txs.timestamp,
            tx_count: result.tx_count,
        };

        // Phase 3: Acquire lock again to update state
        {
            let mut node_state = state.write().unwrap();
            
            // Log with mempool info
            let pending = node_state.mempool.len();
            if pending > 0 || mempool_len > 0 {
                info!(
                    "Block {} produced: txs={}/{}, pending={}, state={}",
                    block_info.number,
                    result.success_count,
                    result.tx_count,
                    pending,
                    hex::encode(&block_info.state_hash[..4]),
                );
            } else {
                info!(
                    "Block {} produced: txs={}/{}, state={}",
                    block_info.number,
                    result.success_count,
                    result.tx_count,
                    hex::encode(&block_info.state_hash[..4]),
                );
            }

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
        } // Lock released here!
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

/// Transaction input for RPC
#[derive(Deserialize)]
struct TxInput {
    #[serde(default)]
    tx_type: String,  // "transfer" or "swap"
    from: String,     // hex address
    to: String,       // hex address
    amount: u64,
    #[serde(default)]
    nonce: u64,
}

/// RPC handler
async fn rpc_handler(
    AxumState(state): AxumState<SharedState>,
    Json(req): Json<RpcRequest>,
) -> Json<RpcResponse> {
    // Handle write operations first
    if req.method == "x2_sendTransaction" {
        return handle_send_transaction(state, req).await;
    }
    if req.method == "x2_sendTransactionBatch" {
        return handle_send_transaction_batch(state, req).await;
    }

    // Read operations
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
        "x2_getMempoolStats" => {
            serde_json::json!({
                "pending": node_state.mempool.len(),
                "totalReceived": node_state.mempool.total_received,
                "totalIncluded": node_state.mempool.total_included,
                "maxSize": node_state.config.mempool_size
            })
        }
        "x2_getPendingCount" => {
            serde_json::json!(node_state.mempool.len())
        }
        _ => serde_json::json!(null),
    };

    Json(RpcResponse {
        jsonrpc: "2.0".to_string(),
        result,
        id: req.id,
    })
}

/// Handle x2_sendTransaction
async fn handle_send_transaction(
    state: SharedState,
    req: RpcRequest,
) -> Json<RpcResponse> {
    let result = if let Some(params) = req.params {
        if let Some(tx_input) = params.as_array().and_then(|arr| arr.first()) {
            match serde_json::from_value::<TxInput>(tx_input.clone()) {
                Ok(input) => {
                    let tx = parse_tx_input(&input);
                    let tx_hash = compute_tx_hash(&tx);
                    
                    let mut node_state = state.write().unwrap();
                    if node_state.mempool.add(tx) {
                        serde_json::json!({
                            "success": true,
                            "txHash": format!("0x{}", hex::encode(tx_hash))
                        })
                    } else {
                        serde_json::json!({
                            "success": false,
                            "error": "mempool full"
                        })
                    }
                }
                Err(e) => {
                    serde_json::json!({
                        "success": false,
                        "error": format!("invalid tx: {}", e)
                    })
                }
            }
        } else {
            serde_json::json!({"success": false, "error": "no tx provided"})
        }
    } else {
        serde_json::json!({"success": false, "error": "no params"})
    };

    Json(RpcResponse {
        jsonrpc: "2.0".to_string(),
        result,
        id: req.id,
    })
}

/// Handle x2_sendTransactionBatch (for benchmarking)
async fn handle_send_transaction_batch(
    state: SharedState,
    req: RpcRequest,
) -> Json<RpcResponse> {
    let result = if let Some(params) = req.params {
        if let Some(txs) = params.as_array().and_then(|arr| arr.first()).and_then(|v| v.as_array()) {
            let mut success = 0;
            let mut failed = 0;
            
            let mut node_state = state.write().unwrap();
            for tx_val in txs {
                if let Ok(input) = serde_json::from_value::<TxInput>(tx_val.clone()) {
                    let tx = parse_tx_input(&input);
                    if node_state.mempool.add(tx) {
                        success += 1;
                    } else {
                        failed += 1;
                    }
                } else {
                    failed += 1;
                }
            }
            
            serde_json::json!({
                "success": success,
                "failed": failed,
                "pending": node_state.mempool.len()
            })
        } else {
            serde_json::json!({"success": 0, "failed": 0, "error": "invalid batch format"})
        }
    } else {
        serde_json::json!({"success": 0, "failed": 0, "error": "no params"})
    };

    Json(RpcResponse {
        jsonrpc: "2.0".to_string(),
        result,
        id: req.id,
    })
}

/// Parse TxInput to Transaction
fn parse_tx_input(input: &TxInput) -> Transaction {
    let mut from = [0u8; 32];
    let mut to = [0u8; 32];
    
    // Parse hex addresses
    if let Ok(bytes) = hex::decode(input.from.trim_start_matches("0x")) {
        let len = bytes.len().min(32);
        from[32-len..].copy_from_slice(&bytes[..len]);
    }
    if let Ok(bytes) = hex::decode(input.to.trim_start_matches("0x")) {
        let len = bytes.len().min(32);
        to[32-len..].copy_from_slice(&bytes[..len]);
    }
    
    let tx_type = match input.tx_type.as_str() {
        "swap" => TxType::Swap,
        _ => TxType::Transfer,
    };
    
    Transaction {
        tx_type,
        from,
        to,
        amount: input.amount as u128,
        nonce: input.nonce,
    }
}

/// Compute simple tx hash
fn compute_tx_hash(tx: &Transaction) -> [u8; 32] {
    use tiny_keccak::{Hasher, Keccak};
    let mut hasher = Keccak::v256();
    hasher.update(&tx.from);
    hasher.update(&tx.to);
    hasher.update(&tx.amount.to_be_bytes());
    hasher.update(&tx.nonce.to_be_bytes());
    let mut output = [0u8; 32];
    hasher.finalize(&mut output);
    output
}
