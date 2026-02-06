//! Proposer logic

use anyhow::{Result, anyhow};
use std::collections::HashMap;
use std::sync::Arc;
use tiny_keccak::{Hasher, Keccak};
use tokio::sync::RwLock;
use tracing::{info, warn, error};

use crate::bisection::{BisectionManager, BisectionResponse};
use crate::config::Config;
use crate::Prover;
use crate::witness::BlockWitness;
use xlayer_core::{Block, State, TraceLog, Hash};

/// Compute keccak256 hash
fn tiny_keccak_hash(data: &[u8]) -> [u8; 32] {
    let mut hasher = Keccak::v256();
    hasher.update(data);
    let mut output = [0u8; 32];
    hasher.finalize(&mut output);
    output
}

/// Batch info from L2 node
#[derive(Debug, Clone)]
pub struct BatchInfo {
    pub index: u64,
    pub start_block: u64,
    pub end_block: u64,
    pub state_root: Hash,
    pub trace_hash: Hash,
}

/// Bisection claim from L1
#[derive(Debug, Clone)]
pub struct ProposerBisectionClaim {
    pub block_number: u64,
    pub trace_hash: Hash,
}

/// Proposer state
pub struct Proposer {
    config: Config,
    state: Arc<RwLock<State>>,
    trace_log: Arc<RwLock<TraceLog>>,
    prover: Prover,
    /// Active bisection games (game_address -> manager)
    active_games: HashMap<String, BisectionManager>,
    /// Current block number from L2
    current_block: u64,
    /// Last submitted batch index
    last_submitted_batch: i64,
    /// HTTP client for RPC calls
    http_client: reqwest::Client,
}

impl Proposer {
    /// Create a new proposer
    pub fn new(config: Config) -> Self {
        let prover = Prover::new(config.sp1.clone());
        
        Self {
            config,
            state: Arc::new(RwLock::new(State::new())),
            trace_log: Arc::new(RwLock::new(TraceLog::new())),
            prover,
            active_games: HashMap::new(),
            current_block: 0,
            last_submitted_batch: -1,
            http_client: reqwest::Client::new(),
        }
    }

    /// Run the proposer main loop
    pub async fn run(&mut self) -> Result<()> {
        info!("Proposer starting...");
        info!("  L1 RPC: {}", self.config.l1_rpc);
        info!("  L2 RPC: {}", self.config.l2_rpc);
        info!("  Batch interval: {} blocks", self.config.batch_interval);
        info!("  SP1 mode: {:?}", self.config.sp1.prover_mode);

        loop {
            // 1. Sync with L2 node - get current block
            match self.sync_l2_state().await {
                Ok(block_num) => {
                    if block_num != self.current_block {
                        self.current_block = block_num;
                        if block_num % 50 == 0 {
                            info!("Synced to L2 block {}", block_num);
                        }
                    }
                }
                Err(e) => {
                    warn!("Failed to sync L2 state: {}", e);
                }
            }

            // 2. Check for new batches from L2 node
            match self.check_and_submit_batches().await {
                Ok(submitted) => {
                    if submitted > 0 {
                        info!("Submitted {} batches to L1", submitted);
                    }
                }
                Err(e) => {
                    warn!("Failed to check/submit batches: {}", e);
                }
            }

            // 3. Handle any active challenges
            if let Err(e) = self.handle_active_challenges().await {
                warn!("Failed to handle challenges: {}", e);
            }

            // Wait before next iteration
            tokio::time::sleep(tokio::time::Duration::from_secs(self.config.fetch_interval)).await;
        }
    }

    /// Call L2 node RPC
    async fn rpc_call(&self, method: &str, params: serde_json::Value) -> Result<serde_json::Value> {
        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": 1
        });

        let response = self.http_client
            .post(&self.config.l2_rpc)
            .json(&request)
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        response.get("result")
            .cloned()
            .ok_or_else(|| anyhow!("No result in response"))
    }

    /// Sync state from L2 node
    async fn sync_l2_state(&mut self) -> Result<u64> {
        let result = self.rpc_call("x2_blockNumber", serde_json::json!([])).await?;
        
        // Parse hex block number
        let block_str = result.as_str().ok_or_else(|| anyhow!("Invalid block number"))?;
        let block_num = u64::from_str_radix(block_str.trim_start_matches("0x"), 16)?;
        
        Ok(block_num)
    }

    /// Check for new batches from L2 and submit to L1
    async fn check_and_submit_batches(&mut self) -> Result<u64> {
        // Get batch count from L2 node
        let batch_count = self.rpc_call("x2_getBatchCount", serde_json::json!([])).await?;
        let batch_count = batch_count.as_u64().unwrap_or(0);

        if batch_count == 0 {
            return Ok(0);
        }

        let mut submitted = 0u64;

        // Submit any new batches
        for batch_idx in (self.last_submitted_batch + 1) as u64..batch_count {
            // Get batch info from L2 node
            let batch_info = self.rpc_call("x2_getBatch", serde_json::json!([batch_idx])).await?;
            
            if batch_info.is_null() {
                continue;
            }

            let batch = self.parse_batch_info(&batch_info)?;
            
            // Submit to L1
            self.submit_batch_to_l1(&batch).await?;
            
            self.last_submitted_batch = batch_idx as i64;
            submitted += 1;
            
            info!(
                "✓ Submitted batch {} to L1 (blocks {}-{}, state_root={})",
                batch.index,
                batch.start_block,
                batch.end_block,
                hex::encode(&batch.state_root[..4])
            );
        }

        Ok(submitted)
    }

    /// Parse batch info from JSON
    fn parse_batch_info(&self, json: &serde_json::Value) -> Result<BatchInfo> {
        let index = json["index"].as_u64().ok_or_else(|| anyhow!("Missing index"))?;
        let start_block = json["startBlock"].as_u64().ok_or_else(|| anyhow!("Missing startBlock"))?;
        let end_block = json["endBlock"].as_u64().ok_or_else(|| anyhow!("Missing endBlock"))?;
        
        let state_root_str = json["stateRoot"].as_str().ok_or_else(|| anyhow!("Missing stateRoot"))?;
        let trace_hash_str = json["traceHash"].as_str().ok_or_else(|| anyhow!("Missing traceHash"))?;
        
        let state_root = self.parse_hash(state_root_str)?;
        let trace_hash = self.parse_hash(trace_hash_str)?;
        
        Ok(BatchInfo {
            index,
            start_block,
            end_block,
            state_root,
            trace_hash,
        })
    }

    /// Parse hex hash string
    fn parse_hash(&self, hex_str: &str) -> Result<Hash> {
        let bytes = hex::decode(hex_str.trim_start_matches("0x"))?;
        if bytes.len() != 32 {
            return Err(anyhow!("Invalid hash length"));
        }
        let mut hash = [0u8; 32];
        hash.copy_from_slice(&bytes);
        Ok(hash)
    }

    /// Submit batch to L1 OutputOracle contract
    async fn submit_batch_to_l1(&self, batch: &BatchInfo) -> Result<()> {
        info!("  → Submitting to L1 OutputOracle:");
        info!("      blocks: {} - {}", batch.start_block, batch.end_block);
        info!("      state_root: 0x{}", hex::encode(&batch.state_root[..8]));
        info!("      trace_hash: 0x{}", hex::encode(&batch.trace_hash[..8]));

        // Get contract address from config
        let output_oracle = self.config.output_oracle_address.as_ref()
            .ok_or_else(|| anyhow!("OUTPUT_ORACLE_ADDRESS not configured"))?;

        // Encode function call: submitOutput(bytes32, bytes32, bytes32, uint64, uint64)
        // Function selector: keccak256("submitOutput(bytes32,bytes32,bytes32,uint64,uint64)")[:4]
        let selector = &tiny_keccak_hash(b"submitOutput(bytes32,bytes32,bytes32,uint64,uint64)")[..4];
        
        let mut calldata = Vec::with_capacity(4 + 32 * 5);
        calldata.extend_from_slice(selector);
        calldata.extend_from_slice(&batch.state_root);  // _stateHash
        calldata.extend_from_slice(&batch.trace_hash);  // _traceHash
        calldata.extend_from_slice(&batch.state_root);  // _smtRoot (use state_root for now)
        calldata.extend_from_slice(&[0u8; 24]);         // padding for uint64
        calldata.extend_from_slice(&batch.start_block.to_be_bytes());
        calldata.extend_from_slice(&[0u8; 24]);         // padding for uint64
        calldata.extend_from_slice(&batch.end_block.to_be_bytes());

        // Get proposer address (Anvil account 1)
        let from_address = self.config.proposer_address.as_ref()
            .map(|s| s.as_str())
            .unwrap_or("0x70997970C51812dc3A010C7d01b50e0d17dc79C8");

        // Send transaction via eth_sendTransaction (works with Anvil's unlocked accounts)
        let tx_request = serde_json::json!({
            "from": from_address,
            "to": output_oracle,
            "data": format!("0x{}", hex::encode(&calldata)),
            "gas": "0x100000"
        });

        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "method": "eth_sendTransaction",
            "params": [tx_request],
            "id": 1
        });

        let response = self.http_client
            .post(&self.config.l1_rpc)
            .json(&request)
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        if let Some(error) = response.get("error") {
            return Err(anyhow!("L1 transaction failed: {:?}", error));
        }

        let tx_hash = response.get("result")
            .and_then(|r| r.as_str())
            .ok_or_else(|| anyhow!("No tx hash in response"))?;

        info!("      tx_hash: {}", tx_hash);
        
        // Wait for receipt
        tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
        
        let receipt_request = serde_json::json!({
            "jsonrpc": "2.0",
            "method": "eth_getTransactionReceipt",
            "params": [tx_hash],
            "id": 1
        });

        let receipt_response = self.http_client
            .post(&self.config.l1_rpc)
            .json(&receipt_request)
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        let status = receipt_response
            .get("result")
            .and_then(|r| r.get("status"))
            .and_then(|s| s.as_str());

        if status == Some("0x1") {
            info!("      ✓ Transaction confirmed!");
        } else {
            warn!("      ⚠ Transaction may have failed: {:?}", status);
        }

        Ok(())
    }

    /// Handle active challenges - check L1 for new games and respond to bisection
    async fn handle_active_challenges(&mut self) -> Result<()> {
        // Check for new games from factory
        if let Err(e) = self.check_for_new_games().await {
            warn!("Failed to check for new games: {}", e);
        }

        // Handle each active game
        let game_addresses: Vec<String> = self.active_games.keys().cloned().collect();
        
        for game_address in game_addresses {
            // Check game status
            let status = self.get_game_status(&game_address).await.unwrap_or(0);
            
            // 0 = IN_PROGRESS, 1 = CHALLENGER_WINS, 2 = DEFENDER_WINS
            if status != 0 {
                info!("Game {} resolved with status {}", game_address, status);
                self.active_games.remove(&game_address);
                continue;
            }

            // Check bisection status
            let bisection_status = self.get_bisection_status(&game_address).await.unwrap_or(0);
            
            // 0 = NOT_STARTED, 1 = IN_PROGRESS, 2 = COMPLETED
            if bisection_status == 0 {
                // Need to start bisection
                if let Err(e) = self.start_bisection(&game_address).await {
                    warn!("Failed to start bisection for {}: {}", game_address, e);
                }
            } else if bisection_status == 1 {
                // Check if it's our turn
                let is_our_turn = self.check_is_proposer_turn(&game_address).await.unwrap_or(false);
                
                if is_our_turn {
                    if let Err(e) = self.respond_to_bisection_l1(&game_address).await {
                        warn!("Failed to respond to bisection: {}", e);
                    }
                }
            } else if bisection_status == 2 {
                // Bisection complete, need to submit proof
                // Get disputed block from L1 contract (not local state)
                let disputed_block = match self.get_disputed_block_from_l1(&game_address).await {
                    Ok(block) => block,
                    Err(e) => {
                        warn!("Failed to get disputed block from L1: {}", e);
                        continue;
                    }
                };
                
                info!("Game {} bisection complete, preparing ZK proof for block {}...", 
                      game_address, disputed_block);
                
                match self.submit_proof(game_address.clone(), disputed_block).await {
                    Ok(_) => {
                        info!("✓ Proof submitted for game {}", game_address);
                        // Remove from active games after successful proof submission
                        self.active_games.remove(&game_address);
                    }
                    Err(e) => {
                        error!("Failed to submit proof for game {}: {}", game_address, e);
                    }
                }
            }
        }

        Ok(())
    }

    /// Check for new dispute games from factory
    async fn check_for_new_games(&mut self) -> Result<()> {
        let factory = &self.config.dispute_game_factory;
        if factory.is_empty() {
            // Only log once per minute to avoid spam
            static LAST_LOG: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs();
            if now - LAST_LOG.load(std::sync::atomic::Ordering::Relaxed) > 60 {
                warn!("No DISPUTE_GAME_FACTORY_ADDRESS configured, skipping challenge monitoring");
                LAST_LOG.store(now, std::sync::atomic::Ordering::Relaxed);
            }
            return Ok(());
        }

        // Get games count
        let selector = &tiny_keccak_hash(b"gamesCount()")[..4];
        
        let result = self.rpc_call_l1("eth_call", serde_json::json!([
            {
                "to": factory,
                "data": format!("0x{}", hex::encode(selector))
            },
            "latest"
        ])).await?;

        let hex_result = result.as_str().ok_or_else(|| anyhow!("Invalid result"))?;
        let bytes = hex::decode(hex_result.trim_start_matches("0x"))?;
        
        if bytes.len() < 32 {
            return Ok(());
        }

        let mut count_bytes = [0u8; 8];
        count_bytes.copy_from_slice(&bytes[24..32]);
        let count = u64::from_be_bytes(count_bytes);

        // Check each game that we're not tracking
        for i in 0..count {
            // Get game address
            let game_selector = &tiny_keccak_hash(b"games(uint256)")[..4];
            let mut calldata = Vec::with_capacity(36);
            calldata.extend_from_slice(game_selector);
            let mut idx_bytes = [0u8; 32];
            idx_bytes[24..32].copy_from_slice(&i.to_be_bytes());
            calldata.extend_from_slice(&idx_bytes);

            let game_result = self.rpc_call_l1("eth_call", serde_json::json!([
                {
                    "to": factory,
                    "data": format!("0x{}", hex::encode(&calldata))
                },
                "latest"
            ])).await?;

            let hex_result = game_result.as_str().ok_or_else(|| anyhow!("Invalid result"))?;
            let addr_bytes = hex::decode(hex_result.trim_start_matches("0x"))?;
            
            if addr_bytes.len() < 32 {
                continue;
            }

            let game_address = format!("0x{}", hex::encode(&addr_bytes[12..32]));

            // Check if we're already tracking this game
            if self.active_games.contains_key(&game_address) {
                continue;
            }

            // Check if this game involves us (we are the proposer)
            let proposer_selector = &tiny_keccak_hash(b"proposer()")[..4];
            let proposer_result = self.rpc_call_l1("eth_call", serde_json::json!([
                {
                    "to": &game_address,
                    "data": format!("0x{}", hex::encode(proposer_selector))
                },
                "latest"
            ])).await?;

            let proposer_hex = proposer_result.as_str().ok_or_else(|| anyhow!("Invalid result"))?;
            let proposer_bytes = hex::decode(proposer_hex.trim_start_matches("0x"))?;
            let game_proposer = format!("0x{}", hex::encode(&proposer_bytes[12..32]));

            // Check if our address matches (Anvil account 1 is the proposer)
            let our_address = self.config.proposer_address.as_ref()
                .map(|s| s.to_lowercase())
                .unwrap_or_else(|| "0x70997970c51812dc3a010c7d01b50e0d17dc79c8".to_string());

            if game_proposer.to_lowercase() == our_address {
                // Check if game is already resolved
                let status = self.get_game_status(&game_address).await.unwrap_or(0);
                if status != 0 {
                    // Game already resolved, skip
                    continue;
                }
                
                info!("Found new challenge game: {}", game_address);
                
                // Get batch range
                let (start, end) = self.get_bisection_range(&game_address).await.unwrap_or((0, 0));
                
                let trace_log = self.trace_log.read().await;
                let manager = BisectionManager::new(start, end, trace_log.clone(), true);
                drop(trace_log);
                
                self.active_games.insert(game_address.clone(), manager);
            }
        }

        Ok(())
    }

    /// Get bisection range from game
    async fn get_bisection_range(&self, game_address: &str) -> Result<(u64, u64)> {
        let selector = &tiny_keccak_hash(b"getBisectionRange()")[..4];
        
        let result = self.rpc_call_l1("eth_call", serde_json::json!([
            {
                "to": game_address,
                "data": format!("0x{}", hex::encode(selector))
            },
            "latest"
        ])).await?;

        let hex_result = result.as_str().ok_or_else(|| anyhow!("Invalid result"))?;
        let bytes = hex::decode(hex_result.trim_start_matches("0x"))?;

        if bytes.len() < 64 {
            return Err(anyhow!("Invalid range data"));
        }

        let mut start_bytes = [0u8; 8];
        let mut end_bytes = [0u8; 8];
        start_bytes.copy_from_slice(&bytes[24..32]);
        end_bytes.copy_from_slice(&bytes[56..64]);

        Ok((u64::from_be_bytes(start_bytes), u64::from_be_bytes(end_bytes)))
    }

    /// Get game status
    async fn get_game_status(&self, game_address: &str) -> Result<u8> {
        let selector = &tiny_keccak_hash(b"status()")[..4];
        
        let result = self.rpc_call_l1("eth_call", serde_json::json!([
            {
                "to": game_address,
                "data": format!("0x{}", hex::encode(selector))
            },
            "latest"
        ])).await?;

        let hex_result = result.as_str().ok_or_else(|| anyhow!("Invalid result"))?;
        let bytes = hex::decode(hex_result.trim_start_matches("0x"))?;
        
        Ok(bytes.last().copied().unwrap_or(0))
    }

    /// Get bisection status
    async fn get_bisection_status(&self, game_address: &str) -> Result<u8> {
        let selector = &tiny_keccak_hash(b"bisectionStatus()")[..4];
        
        let result = self.rpc_call_l1("eth_call", serde_json::json!([
            {
                "to": game_address,
                "data": format!("0x{}", hex::encode(selector))
            },
            "latest"
        ])).await?;

        let hex_result = result.as_str().ok_or_else(|| anyhow!("Invalid result"))?;
        let bytes = hex::decode(hex_result.trim_start_matches("0x"))?;
        
        Ok(bytes.last().copied().unwrap_or(0))
    }

    /// Get disputed block from L1 DisputeGame contract
    async fn get_disputed_block_from_l1(&self, game_address: &str) -> Result<u64> {
        let selector = &tiny_keccak_hash(b"disputedBlock()")[..4];
        
        let result = self.rpc_call_l1("eth_call", serde_json::json!([
            {
                "to": game_address,
                "data": format!("0x{}", hex::encode(selector))
            },
            "latest"
        ])).await?;

        let hex_result = result.as_str().ok_or_else(|| anyhow!("Invalid result"))?;
        let bytes = hex::decode(hex_result.trim_start_matches("0x"))?;

        if bytes.len() < 32 {
            return Err(anyhow!("Invalid disputed block data"));
        }

        let mut block_bytes = [0u8; 8];
        block_bytes.copy_from_slice(&bytes[24..32]);
        Ok(u64::from_be_bytes(block_bytes))
    }

    /// Check if it's proposer's turn
    async fn check_is_proposer_turn(&self, game_address: &str) -> Result<bool> {
        let selector = &tiny_keccak_hash(b"isProposerTurn()")[..4];
        
        let result = self.rpc_call_l1("eth_call", serde_json::json!([
            {
                "to": game_address,
                "data": format!("0x{}", hex::encode(selector))
            },
            "latest"
        ])).await?;

        let hex_result = result.as_str().ok_or_else(|| anyhow!("Invalid result"))?;
        let bytes = hex::decode(hex_result.trim_start_matches("0x"))?;
        
        Ok(bytes.last().map(|&b| b != 0).unwrap_or(false))
    }

    /// Start bisection (proposer's first move)
    async fn start_bisection(&mut self, game_address: &str) -> Result<()> {
        let (start, end) = self.get_bisection_range(game_address).await?;
        let mid = (start + end) / 2;
        
        // Get our trace hash at mid block
        let trace_log = self.trace_log.read().await;
        let trace_hash = trace_log.get_trace_at(mid).unwrap_or([0u8; 32]);
        drop(trace_log);

        info!("Starting bisection for game {}, mid block {}", game_address, mid);

        // Call startBisection(uint64, bytes32)
        let selector = &tiny_keccak_hash(b"startBisection(uint64,bytes32)")[..4];
        
        let mut calldata = Vec::with_capacity(68);
        calldata.extend_from_slice(selector);
        
        let mut block_bytes = [0u8; 32];
        block_bytes[24..32].copy_from_slice(&mid.to_be_bytes());
        calldata.extend_from_slice(&block_bytes);
        calldata.extend_from_slice(&trace_hash);

        let from_address = self.config.proposer_address.as_ref()
            .map(|s| s.as_str())
            .unwrap_or("0x70997970C51812dc3A010C7d01b50e0d17dc79C8");

        let tx_request = serde_json::json!({
            "from": from_address,
            "to": game_address,
            "data": format!("0x{}", hex::encode(&calldata)),
            "gas": "0x100000"
        });

        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "method": "eth_sendTransaction",
            "params": [tx_request],
            "id": 1
        });

        let response = self.http_client
            .post(&self.config.l1_rpc)
            .json(&request)
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        if let Some(error) = response.get("error") {
            return Err(anyhow!("Failed to start bisection: {:?}", error));
        }

        let tx_hash = response.get("result")
            .and_then(|r| r.as_str())
            .ok_or_else(|| anyhow!("No tx hash"))?;

        info!("  tx_hash: {}", tx_hash);
        
        tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;

        Ok(())
    }

    /// Respond to bisection move on L1
    async fn respond_to_bisection_l1(&mut self, game_address: &str) -> Result<()> {
        // Get latest claim
        let claim = self.get_latest_bisection_claim(game_address).await?;
        
        // Get manager
        let manager = self.active_games.get_mut(game_address)
            .ok_or_else(|| anyhow!("Game not found"))?;

        // Process opponent's claim
        let response = manager.process_opponent_claim(claim.block_number, claim.trace_hash);

        match response {
            BisectionResponse::Agree { our_mid_block, our_trace_hash } => {
                info!("Game {}: AGREE at block {}, responding with mid={}", 
                      game_address, claim.block_number, our_mid_block);
                self.submit_bisection_response(game_address, true, our_mid_block, our_trace_hash).await?;
            }
            BisectionResponse::Disagree { our_mid_block, our_trace_hash } => {
                info!("Game {}: DISAGREE at block {}, responding with mid={}", 
                      game_address, claim.block_number, our_mid_block);
                self.submit_bisection_response(game_address, false, our_mid_block, our_trace_hash).await?;
            }
            BisectionResponse::Complete { disputed_block } => {
                // Local manager thinks it's complete, but chain might not be
                // Submit one more bisect to potentially trigger chain completion
                let trace_hash = manager.get_trace_hash(disputed_block).unwrap_or([0u8; 32]);
                info!("Game {} local bisection complete, submitting final bisect for block {}", 
                      game_address, disputed_block);
                
                // Submit as agree with the disputed block to potentially complete chain bisection
                if let Err(e) = self.submit_bisection_response(game_address, true, disputed_block, trace_hash).await {
                    // If this fails, chain bisection is likely already complete or we're not in our turn
                    warn!("Final bisect submission failed (expected if chain already complete): {}", e);
                }
            }
        }

        Ok(())
    }

    /// Get latest bisection claim
    async fn get_latest_bisection_claim(&self, game_address: &str) -> Result<ProposerBisectionClaim> {
        let count_selector = &tiny_keccak_hash(b"getBisectionClaimsCount()")[..4];
        
        let count_result = self.rpc_call_l1("eth_call", serde_json::json!([
            {
                "to": game_address,
                "data": format!("0x{}", hex::encode(count_selector))
            },
            "latest"
        ])).await?;

        let hex_result = count_result.as_str().ok_or_else(|| anyhow!("Invalid result"))?;
        let bytes = hex::decode(hex_result.trim_start_matches("0x"))?;
        
        let mut count_bytes = [0u8; 8];
        count_bytes.copy_from_slice(&bytes[24..32]);
        let count = u64::from_be_bytes(count_bytes);

        if count == 0 {
            return Err(anyhow!("No claims yet"));
        }

        let claim_selector = &tiny_keccak_hash(b"getBisectionClaim(uint256)")[..4];
        let mut calldata = Vec::with_capacity(36);
        calldata.extend_from_slice(claim_selector);
        let mut index_bytes = [0u8; 32];
        index_bytes[24..32].copy_from_slice(&(count - 1).to_be_bytes());
        calldata.extend_from_slice(&index_bytes);

        let claim_result = self.rpc_call_l1("eth_call", serde_json::json!([
            {
                "to": game_address,
                "data": format!("0x{}", hex::encode(&calldata))
            },
            "latest"
        ])).await?;

        let hex_result = claim_result.as_str().ok_or_else(|| anyhow!("Invalid result"))?;
        let bytes = hex::decode(hex_result.trim_start_matches("0x"))?;

        let mut block_bytes = [0u8; 8];
        block_bytes.copy_from_slice(&bytes[24..32]);
        let block_number = u64::from_be_bytes(block_bytes);

        let mut trace_hash = [0u8; 32];
        trace_hash.copy_from_slice(&bytes[32..64]);

        Ok(ProposerBisectionClaim {
            block_number,
            trace_hash,
        })
    }

    /// Submit bisection response
    async fn submit_bisection_response(&self, game_address: &str, agree: bool, mid_block: u64, trace_hash: Hash) -> Result<()> {
        let selector = &tiny_keccak_hash(b"bisect(bool,uint64,bytes32)")[..4];
        
        let mut calldata = Vec::with_capacity(100);
        calldata.extend_from_slice(selector);
        
        let mut agree_bytes = [0u8; 32];
        agree_bytes[31] = if agree { 1 } else { 0 };
        calldata.extend_from_slice(&agree_bytes);
        
        let mut block_bytes = [0u8; 32];
        block_bytes[24..32].copy_from_slice(&mid_block.to_be_bytes());
        calldata.extend_from_slice(&block_bytes);
        
        calldata.extend_from_slice(&trace_hash);

        let from_address = self.config.proposer_address.as_ref()
            .map(|s| s.as_str())
            .unwrap_or("0x70997970C51812dc3A010C7d01b50e0d17dc79C8");

        let tx_request = serde_json::json!({
            "from": from_address,
            "to": game_address,
            "data": format!("0x{}", hex::encode(&calldata)),
            "gas": "0x100000"
        });

        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "method": "eth_sendTransaction",
            "params": [tx_request],
            "id": 1
        });

        let response = self.http_client
            .post(&self.config.l1_rpc)
            .json(&request)
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        if let Some(error) = response.get("error") {
            return Err(anyhow!("Bisection tx failed: {:?}", error));
        }

        let tx_hash = response.get("result")
            .and_then(|r| r.as_str())
            .ok_or_else(|| anyhow!("No tx hash"))?;

        info!("      tx_hash: {}", tx_hash);
        
        tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;

        Ok(())
    }

    /// Call L1 RPC
    async fn rpc_call_l1(&self, method: &str, params: serde_json::Value) -> Result<serde_json::Value> {
        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": 1
        });

        let response = self.http_client
            .post(&self.config.l1_rpc)
            .json(&request)
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        response.get("result")
            .cloned()
            .ok_or_else(|| anyhow!("No result in response"))
    }

    /// Submit ZK proof for a disputed block
    async fn submit_proof(&mut self, game_address: String, disputed_block: u64) -> Result<()> {
        info!("Generating proof for block {}...", disputed_block);

        // 1. Get block data from L2
        let block_data = self.rpc_call("x2_getBlock", serde_json::json!([disputed_block])).await?;
        
        info!("  Block data: {:?}", block_data);
        
        // 2. Generate ZK proof using witness
        let state = self.state.read().await;
        let trace_log = self.trace_log.read().await;
        let block = Block::new(disputed_block, [0u8; 32], 0);
        
        // Create witness for prover
        let witness = BlockWitness {
            block: block.clone(),
            initial_states: vec![],
            smt_proofs: vec![],
            prev_smt_root: state.smt_root(),
            prev_state_hash: [0u8; 32],
            prev_trace_hash: [0u8; 32],
        };
        drop(state);
        drop(trace_log);
        
        let proof_result = self.prover.prove(&witness)?;

        info!("  Proof generated: {} bytes", proof_result.proof_bytes.len());

        // 3. Prepare public values (ABI encoded BlockOutput)
        let state = self.state.read().await;
        let trace_log = self.trace_log.read().await;
        let trace_hash = trace_log.get_trace_at(disputed_block).unwrap_or([0u8; 32]);
        let state_hash = state.compute_state_hash(&[0u8; 32]);
        let smt_root = state.smt_root();
        drop(state);
        drop(trace_log);

        // Encode BlockOutput struct for Solidity
        // struct BlockOutput { uint64 blockNumber; bytes32 blockHash; bytes32 stateHash; bytes32 traceHash; bytes32 smtRoot; uint32 successCount; }
        let mut public_values = Vec::with_capacity(192);
        
        // blockNumber (uint64 padded to 32 bytes)
        let mut block_bytes = [0u8; 32];
        block_bytes[24..32].copy_from_slice(&disputed_block.to_be_bytes());
        public_values.extend_from_slice(&block_bytes);
        
        // blockHash (bytes32)
        public_values.extend_from_slice(&block.hash());
        
        // stateHash (bytes32)
        public_values.extend_from_slice(&state_hash);
        
        // traceHash (bytes32)
        public_values.extend_from_slice(&trace_hash);
        
        // smtRoot (bytes32)
        public_values.extend_from_slice(&smt_root);
        
        // successCount (uint32 padded to 32 bytes)
        let mut count_bytes = [0u8; 32];
        count_bytes[28..32].copy_from_slice(&10u32.to_be_bytes()); // mock count
        public_values.extend_from_slice(&count_bytes);

        info!("  Submitting to DisputeGame contract...");

        // 4. Call prove(bytes, bytes) on DisputeGame
        let selector = &tiny_keccak_hash(b"prove(bytes,bytes)")[..4];
        let proof_bytes = &proof_result.proof_bytes;
        
        // ABI encode dynamic bytes
        // offset to first bytes (64 bytes)
        // offset to second bytes (64 + 32 + proof.len() rounded up)
        let proof_offset: u64 = 64;
        let public_values_offset: u64 = 64 + 32 + ((proof_bytes.len() + 31) / 32 * 32) as u64;
        
        let mut calldata = Vec::new();
        calldata.extend_from_slice(selector);
        
        // Offset to proof bytes
        let mut offset_bytes = [0u8; 32];
        offset_bytes[24..32].copy_from_slice(&proof_offset.to_be_bytes());
        calldata.extend_from_slice(&offset_bytes);
        
        // Offset to public_values bytes
        let mut offset_bytes = [0u8; 32];
        offset_bytes[24..32].copy_from_slice(&public_values_offset.to_be_bytes());
        calldata.extend_from_slice(&offset_bytes);
        
        // Proof bytes: length + data
        let mut len_bytes = [0u8; 32];
        len_bytes[24..32].copy_from_slice(&(proof_bytes.len() as u64).to_be_bytes());
        calldata.extend_from_slice(&len_bytes);
        calldata.extend_from_slice(proof_bytes);
        // Pad to 32 bytes
        let padding = (32 - (proof_bytes.len() % 32)) % 32;
        calldata.extend_from_slice(&vec![0u8; padding]);
        
        // Public values bytes: length + data
        let mut len_bytes = [0u8; 32];
        len_bytes[24..32].copy_from_slice(&(public_values.len() as u64).to_be_bytes());
        calldata.extend_from_slice(&len_bytes);
        calldata.extend_from_slice(&public_values);

        let from_address = self.config.proposer_address.as_ref()
            .map(|s| s.as_str())
            .unwrap_or("0x70997970C51812dc3A010C7d01b50e0d17dc79C8");

        let tx_request = serde_json::json!({
            "from": from_address,
            "to": &game_address,
            "data": format!("0x{}", hex::encode(&calldata)),
            "gas": "0x500000"
        });

        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "method": "eth_sendTransaction",
            "params": [tx_request],
            "id": 1
        });

        let response = self.http_client
            .post(&self.config.l1_rpc)
            .json(&request)
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        if let Some(error) = response.get("error") {
            return Err(anyhow!("Prove tx failed: {:?}", error));
        }

        let tx_hash = response.get("result")
            .and_then(|r| r.as_str())
            .ok_or_else(|| anyhow!("No tx hash"))?;

        info!("      tx_hash: {}", tx_hash);
        
        // Wait for confirmation
        tokio::time::sleep(tokio::time::Duration::from_secs(3)).await;
        
        // Check receipt
        let receipt_request = serde_json::json!({
            "jsonrpc": "2.0",
            "method": "eth_getTransactionReceipt",
            "params": [tx_hash],
            "id": 1
        });

        let receipt_response = self.http_client
            .post(&self.config.l1_rpc)
            .json(&receipt_request)
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        let status = receipt_response
            .get("result")
            .and_then(|r| r.get("status"))
            .and_then(|s| s.as_str());

        if status == Some("0x1") {
            info!("      ✓ Proof accepted! Game resolved.");
        } else {
            warn!("      ⚠ Proof may have failed: {:?}", status);
        }
        
        Ok(())
    }

    /// Handle a new challenge
    pub async fn handle_challenge(&mut self, game_address: String, _batch_index: u64, start_block: u64, end_block: u64) -> Result<()> {
        info!("New challenge received for game {}", game_address);
        
        // Create bisection manager
        let trace_log = self.trace_log.read().await;
        let manager = BisectionManager::new(start_block, end_block, trace_log.clone(), true);
        drop(trace_log);
        
        self.active_games.insert(game_address.clone(), manager);
        
        Ok(())
    }

    /// Respond to a bisection round
    pub async fn respond_to_bisection(&mut self, game_address: &str, mid_block: u64, their_trace_hash: Hash) -> Result<BisectionResponse> {
        let manager = self.active_games.get_mut(game_address)
            .ok_or_else(|| anyhow!("Game not found"))?;

        // Use process_opponent_claim instead of respond
        let response = manager.process_opponent_claim(mid_block, their_trace_hash);

        match &response {
            BisectionResponse::Agree { our_mid_block, our_trace_hash: _ } => {
                info!("Bisection: AGREE at block {}, proposing mid={}", mid_block, our_mid_block);
            }
            BisectionResponse::Disagree { our_mid_block, our_trace_hash: _ } => {
                info!("Bisection: DISAGREE at block {}, proposing mid={}", mid_block, our_mid_block);
            }
            BisectionResponse::Complete { disputed_block } => {
                info!("Bisection COMPLETE: disputed block = {}", disputed_block);
            }
        }

        Ok(response)
    }
}
