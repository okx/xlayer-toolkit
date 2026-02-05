//! Challenger logic

use anyhow::{Result, anyhow};
use std::collections::HashMap;
use std::sync::Arc;
use tiny_keccak::{Hasher, Keccak};
use tokio::sync::RwLock;
use tracing::{info, warn, error};

use crate::bisection::{BisectionManager, BisectionResponse};
use crate::config::Config;
use xlayer_core::{State, TraceLog, Hash};

/// Compute keccak256 hash
fn tiny_keccak_hash(data: &[u8]) -> [u8; 32] {
    let mut hasher = Keccak::v256();
    hasher.update(data);
    let mut output = [0u8; 32];
    hasher.finalize(&mut output);
    output
}

/// Output info from L1 OutputOracle
#[derive(Debug, Clone)]
pub struct OutputInfo {
    pub batch_index: u64,
    pub state_hash: Hash,
    pub trace_hash: Hash,
    pub smt_root: Hash,
    pub start_block: u64,
    pub end_block: u64,
}

/// Bisection claim from L1
#[derive(Debug, Clone)]
pub struct BisectionClaim {
    pub block_number: u64,
    pub trace_hash: Hash,
}

/// Challenger state
pub struct Challenger {
    config: Config,
    state: Arc<RwLock<State>>,
    trace_log: Arc<RwLock<TraceLog>>,
    /// Active bisection games (game_address -> manager)
    active_games: HashMap<String, BisectionManager>,
    /// Current block number from L2
    current_block: u64,
    /// Last checked batch index on L1
    last_checked_batch: i64,
    /// Number of challenges initiated
    challenges_initiated: u64,
    /// HTTP client
    http_client: reqwest::Client,
}

impl Challenger {
    /// Create a new challenger
    pub fn new(config: Config) -> Self {
        Self {
            config,
            state: Arc::new(RwLock::new(State::new())),
            trace_log: Arc::new(RwLock::new(TraceLog::new())),
            active_games: HashMap::new(),
            current_block: 0,
            last_checked_batch: -1,
            challenges_initiated: 0,
            http_client: reqwest::Client::new(),
        }
    }

    /// Run the challenger main loop
    pub async fn run(&mut self) -> Result<()> {
        info!("Challenger starting...");
        info!("  L1 RPC: {}", self.config.l1_rpc);
        info!("  L2 RPC: {}", self.config.l2_rpc);
        info!("  Challenge every {} outputs", self.config.challenge_every_n_outputs);

        loop {
            // 1. Sync with L2 node
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

            // 2. Monitor L1 for new batch outputs
            match self.monitor_l1_outputs().await {
                Ok(challenged) => {
                    if challenged > 0 {
                        info!("Initiated {} new challenges", challenged);
                    }
                }
                Err(e) => {
                    warn!("Failed to monitor L1 outputs: {}", e);
                }
            }

            // 3. Handle active challenges
            if let Err(e) = self.handle_active_challenges().await {
                warn!("Failed to handle challenges: {}", e);
            }

            // Wait before next iteration
            tokio::time::sleep(tokio::time::Duration::from_secs(self.config.fetch_interval)).await;
        }
    }

    /// Call RPC
    async fn rpc_call(&self, url: &str, method: &str, params: serde_json::Value) -> Result<serde_json::Value> {
        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": 1
        });

        let response = self.http_client
            .post(url)
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
        let result = self.rpc_call(&self.config.l2_rpc, "x2_blockNumber", serde_json::json!([])).await?;
        
        let block_str = result.as_str().ok_or_else(|| anyhow!("Invalid block number"))?;
        let block_num = u64::from_str_radix(block_str.trim_start_matches("0x"), 16)?;
        
        Ok(block_num)
    }

    /// Monitor L1 for new batch outputs
    async fn monitor_l1_outputs(&mut self) -> Result<u64> {
        let output_oracle = match self.config.output_oracle_address.as_ref() {
            Some(addr) => addr.clone(),
            None => return Ok(0), // No output oracle configured
        };

        // Get next batch index from L1
        let next_batch_index = self.get_l1_next_batch_index(&output_oracle).await?;

        if next_batch_index == 0 {
            return Ok(0);
        }

        let mut challenged = 0u64;

        // Check each new batch
        for batch_idx in (self.last_checked_batch + 1) as u64..next_batch_index {
            // Get output from L1
            let output = match self.get_l1_output(&output_oracle, batch_idx).await {
                Ok(o) => o,
                Err(e) => {
                    warn!("Failed to get output {}: {}", batch_idx, e);
                    continue;
                }
            };

            info!(
                "Found L1 output {}: blocks {}-{}, trace_hash=0x{}",
                batch_idx,
                output.start_block,
                output.end_block,
                hex::encode(&output.trace_hash[..4])
            );

            // For demo: challenge every N outputs
            if batch_idx > 0 && batch_idx % self.config.challenge_every_n_outputs == 0 {
                info!("=== Initiating challenge for output {} ===", batch_idx);

                // Get our trace hash from L2
                let our_trace_hash = self.get_l2_trace_hash(output.end_block).await
                    .unwrap_or([0xFFu8; 32]);

                let force_challenge = self.config.force_challenge;
                let trace_mismatch = our_trace_hash != output.trace_hash;

                if trace_mismatch {
                    info!("  ⚠ Trace hash mismatch!");
                    info!("    L1: 0x{}", hex::encode(&output.trace_hash[..8]));
                    info!("    L2: 0x{}", hex::encode(&our_trace_hash[..8]));
                } else if force_challenge {
                    info!("  ℹ Trace hash matches, but FORCE_CHALLENGE enabled");
                    info!("    (This is for demo/testing purposes)");
                } else {
                    info!("  ✓ Output is valid (trace hash matches)");
                }

                // Initiate challenge if mismatch OR force_challenge enabled
                if trace_mismatch || force_challenge {
                    match self.challenge_batch(&output, our_trace_hash).await {
                        Ok(game_addr) => {
                            info!("  ✓ Challenge created: {}", game_addr);
                            challenged += 1;
                        }
                        Err(e) => {
                            error!("  ✗ Failed to create challenge: {}", e);
                        }
                    }
                }
            }

            self.last_checked_batch = batch_idx as i64;
        }

        Ok(challenged)
    }

    /// Get next batch index from L1 OutputOracle
    async fn get_l1_next_batch_index(&self, output_oracle: &str) -> Result<u64> {
        // Call nextBatchIndex() - selector: 0x8d3b4c20
        let selector = &tiny_keccak_hash(b"nextBatchIndex()")[..4];
        
        let result = self.rpc_call(&self.config.l1_rpc, "eth_call", serde_json::json!([
            {
                "to": output_oracle,
                "data": format!("0x{}", hex::encode(selector))
            },
            "latest"
        ])).await?;

        let hex_result = result.as_str().ok_or_else(|| anyhow!("Invalid result"))?;
        let bytes = hex::decode(hex_result.trim_start_matches("0x"))?;
        
        if bytes.len() < 32 {
            return Ok(0);
        }

        // Parse uint256 as u64
        let mut index_bytes = [0u8; 8];
        index_bytes.copy_from_slice(&bytes[24..32]);
        Ok(u64::from_be_bytes(index_bytes))
    }

    /// Get output from L1 OutputOracle
    async fn get_l1_output(&self, output_oracle: &str, batch_index: u64) -> Result<OutputInfo> {
        // Call getOutput(uint256) - need to encode properly
        let selector = &tiny_keccak_hash(b"getOutput(uint256)")[..4];
        
        let mut calldata = Vec::with_capacity(36);
        calldata.extend_from_slice(selector);
        let mut index_bytes = [0u8; 32];
        index_bytes[24..32].copy_from_slice(&batch_index.to_be_bytes());
        calldata.extend_from_slice(&index_bytes);

        let result = self.rpc_call(&self.config.l1_rpc, "eth_call", serde_json::json!([
            {
                "to": output_oracle,
                "data": format!("0x{}", hex::encode(&calldata))
            },
            "latest"
        ])).await?;

        let hex_result = result.as_str().ok_or_else(|| anyhow!("Invalid result"))?;
        let bytes = hex::decode(hex_result.trim_start_matches("0x"))?;

        if bytes.len() < 224 {
            return Err(anyhow!("Output data too short"));
        }

        // Parse Output struct: (bytes32, bytes32, bytes32, uint64, uint64, uint256, address)
        let mut state_hash = [0u8; 32];
        let mut trace_hash = [0u8; 32];
        let mut smt_root = [0u8; 32];
        
        state_hash.copy_from_slice(&bytes[0..32]);
        trace_hash.copy_from_slice(&bytes[32..64]);
        smt_root.copy_from_slice(&bytes[64..96]);

        let mut start_bytes = [0u8; 8];
        let mut end_bytes = [0u8; 8];
        start_bytes.copy_from_slice(&bytes[120..128]);
        end_bytes.copy_from_slice(&bytes[152..160]);

        Ok(OutputInfo {
            batch_index,
            state_hash,
            trace_hash,
            smt_root,
            start_block: u64::from_be_bytes(start_bytes),
            end_block: u64::from_be_bytes(end_bytes),
        })
    }

    /// Get trace hash from L2 node
    async fn get_l2_trace_hash(&self, block_num: u64) -> Result<Hash> {
        let result = self.rpc_call(&self.config.l2_rpc, "x2_getBlock", serde_json::json!([block_num])).await?;
        
        let trace_str = result.get("traceHash")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("No traceHash in block"))?;

        let bytes = hex::decode(trace_str.trim_start_matches("0x"))?;
        if bytes.len() != 32 {
            return Err(anyhow!("Invalid trace hash length"));
        }

        let mut hash = [0u8; 32];
        hash.copy_from_slice(&bytes);
        Ok(hash)
    }

    /// Challenge an invalid batch by calling DisputeGameFactory.createGame()
    async fn challenge_batch(&mut self, output: &OutputInfo, our_trace_hash: Hash) -> Result<String> {
        info!("Challenging batch {} (blocks {} - {})", output.batch_index, output.start_block, output.end_block);

        let factory_address = &self.config.dispute_game_factory;
        if factory_address.is_empty() {
            // Mock mode: just create a fake game address
            let game_address = format!("0x{:040x}", output.batch_index);
            info!("  (Mock mode - no factory configured)");
            
            let trace_log = self.trace_log.read().await;
            let manager = BisectionManager::new(
                output.start_block,
                output.end_block,
                trace_log.clone(),
                false, // challenger
            );
            drop(trace_log);

            self.active_games.insert(game_address.clone(), manager);
            self.challenges_initiated += 1;
            return Ok(game_address);
        }

        // Call DisputeGameFactory.createGame(uint256, bytes32)
        // Selector: keccak256("createGame(uint256,bytes32)")[:4]
        let selector = &tiny_keccak_hash(b"createGame(uint256,bytes32)")[..4];
        
        let mut calldata = Vec::with_capacity(68);
        calldata.extend_from_slice(selector);
        
        // Encode batch index (uint256)
        let mut batch_bytes = [0u8; 32];
        batch_bytes[24..32].copy_from_slice(&output.batch_index.to_be_bytes());
        calldata.extend_from_slice(&batch_bytes);
        
        // Encode our trace hash (bytes32)
        calldata.extend_from_slice(&our_trace_hash);

        // Get challenger address (Anvil account 2)
        let challenger_address = self.config.private_key.clone();
        let from_address = if challenger_address.is_empty() {
            "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC".to_string() // Anvil account 2
        } else {
            // Derive address from private key (simplified - just use account 2)
            "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC".to_string()
        };

        // Send transaction with bond (0.1 ETH)
        let tx_request = serde_json::json!({
            "from": from_address,
            "to": factory_address,
            "data": format!("0x{}", hex::encode(&calldata)),
            "value": "0x16345785d8a0000", // 0.1 ETH in hex
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
            return Err(anyhow!("Failed to create game: {:?}", error));
        }

        let tx_hash = response.get("result")
            .and_then(|r| r.as_str())
            .ok_or_else(|| anyhow!("No tx hash in response"))?;

        info!("  tx_hash: {}", tx_hash);

        // Wait for receipt
        tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;

        // Get game address from event logs
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

        let receipt = receipt_response.get("result")
            .ok_or_else(|| anyhow!("No receipt"))?;

        let status = receipt.get("status").and_then(|s| s.as_str());
        if status != Some("0x1") {
            return Err(anyhow!("Transaction failed"));
        }

        // Extract game address from logs (first log, third topic is game address)
        let game_address = receipt.get("logs")
            .and_then(|logs| logs.as_array())
            .and_then(|logs| logs.first())
            .and_then(|log| log.get("topics"))
            .and_then(|topics| topics.as_array())
            .and_then(|topics| topics.get(1)) // game address is in data, but batch index is topic 1
            .and_then(|t| t.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| format!("0x{:040x}", output.batch_index));

        // Actually, let's get the game address from the factory
        let game_address = self.get_game_by_batch(factory_address, output.batch_index).await?;

        info!("  ✓ Game created: {}", game_address);

        // Create local bisection manager
        let trace_log = self.trace_log.read().await;
        let manager = BisectionManager::new(
            output.start_block,
            output.end_block,
            trace_log.clone(),
            false, // challenger
        );
        drop(trace_log);

        self.active_games.insert(game_address.clone(), manager);
        self.challenges_initiated += 1;

        Ok(game_address)
    }

    /// Get game address by batch index from factory
    async fn get_game_by_batch(&self, factory: &str, batch_index: u64) -> Result<String> {
        let selector = &tiny_keccak_hash(b"gameByBatch(uint256)")[..4];
        
        let mut calldata = Vec::with_capacity(36);
        calldata.extend_from_slice(selector);
        let mut batch_bytes = [0u8; 32];
        batch_bytes[24..32].copy_from_slice(&batch_index.to_be_bytes());
        calldata.extend_from_slice(&batch_bytes);

        let result = self.rpc_call(&self.config.l1_rpc, "eth_call", serde_json::json!([
            {
                "to": factory,
                "data": format!("0x{}", hex::encode(&calldata))
            },
            "latest"
        ])).await?;

        let hex_result = result.as_str().ok_or_else(|| anyhow!("Invalid result"))?;
        let bytes = hex::decode(hex_result.trim_start_matches("0x"))?;
        
        if bytes.len() < 32 {
            return Err(anyhow!("Invalid address"));
        }

        Ok(format!("0x{}", hex::encode(&bytes[12..32])))
    }

    /// Handle active challenges - check L1 state and respond to bisection
    async fn handle_active_challenges(&mut self) -> Result<()> {
        let game_addresses: Vec<String> = self.active_games.keys().cloned().collect();
        
        for game_address in game_addresses {
            // Check if it's our turn
            let is_our_turn = self.check_is_challenger_turn(&game_address).await.unwrap_or(false);
            
            if !is_our_turn {
                continue;
            }

            // Get the latest bisection claim from L1
            let claim = match self.get_latest_bisection_claim(&game_address).await {
                Ok(c) => c,
                Err(e) => {
                    warn!("Failed to get bisection claim for {}: {}", game_address, e);
                    continue;
                }
            };

            // Get our manager
            let manager = match self.active_games.get_mut(&game_address) {
                Some(m) => m,
                None => continue,
            };

            // Check if bisection is complete locally
            if manager.is_bisection_complete() {
                info!("Game {} bisection complete, waiting for proposer proof", game_address);
                continue;
            }

            // Process the claim and get our response
            let response = manager.process_opponent_claim(claim.block_number, claim.trace_hash);

            // Submit our response to L1
            match response {
                BisectionResponse::Agree { our_mid_block, our_trace_hash } => {
                    info!("Game {}: AGREE at block {}, responding with mid={}", 
                          game_address, claim.block_number, our_mid_block);
                    if let Err(e) = self.submit_bisection_response(&game_address, true, our_mid_block, our_trace_hash).await {
                        error!("Failed to submit bisection response: {}", e);
                    }
                }
                BisectionResponse::Disagree { our_mid_block, our_trace_hash } => {
                    info!("Game {}: DISAGREE at block {}, responding with mid={}", 
                          game_address, claim.block_number, our_mid_block);
                    if let Err(e) = self.submit_bisection_response(&game_address, false, our_mid_block, our_trace_hash).await {
                        error!("Failed to submit bisection response: {}", e);
                    }
                }
                BisectionResponse::Complete { disputed_block } => {
                    info!("Game {} bisection COMPLETE! Disputed block: {}", game_address, disputed_block);
                }
            }
        }
        Ok(())
    }

    /// Check if it's challenger's turn in the game
    async fn check_is_challenger_turn(&self, game_address: &str) -> Result<bool> {
        let selector = &tiny_keccak_hash(b"isProposerTurn()")[..4];
        
        let result = self.rpc_call(&self.config.l1_rpc, "eth_call", serde_json::json!([
            {
                "to": game_address,
                "data": format!("0x{}", hex::encode(selector))
            },
            "latest"
        ])).await?;

        let hex_result = result.as_str().ok_or_else(|| anyhow!("Invalid result"))?;
        let bytes = hex::decode(hex_result.trim_start_matches("0x"))?;
        
        // If isProposerTurn is false, it's challenger's turn
        let is_proposer_turn = bytes.last().map(|&b| b != 0).unwrap_or(true);
        Ok(!is_proposer_turn)
    }

    /// Get the latest bisection claim from L1
    async fn get_latest_bisection_claim(&self, game_address: &str) -> Result<BisectionClaim> {
        // First get claims count
        let count_selector = &tiny_keccak_hash(b"getBisectionClaimsCount()")[..4];
        
        let count_result = self.rpc_call(&self.config.l1_rpc, "eth_call", serde_json::json!([
            {
                "to": game_address,
                "data": format!("0x{}", hex::encode(count_selector))
            },
            "latest"
        ])).await?;

        let hex_result = count_result.as_str().ok_or_else(|| anyhow!("Invalid result"))?;
        let bytes = hex::decode(hex_result.trim_start_matches("0x"))?;
        
        if bytes.len() < 32 {
            return Err(anyhow!("No claims yet"));
        }

        let mut count_bytes = [0u8; 8];
        count_bytes.copy_from_slice(&bytes[24..32]);
        let count = u64::from_be_bytes(count_bytes);

        if count == 0 {
            return Err(anyhow!("No claims yet"));
        }

        // Get the latest claim
        let claim_selector = &tiny_keccak_hash(b"getBisectionClaim(uint256)")[..4];
        let mut calldata = Vec::with_capacity(36);
        calldata.extend_from_slice(claim_selector);
        let mut index_bytes = [0u8; 32];
        index_bytes[24..32].copy_from_slice(&(count - 1).to_be_bytes());
        calldata.extend_from_slice(&index_bytes);

        let claim_result = self.rpc_call(&self.config.l1_rpc, "eth_call", serde_json::json!([
            {
                "to": game_address,
                "data": format!("0x{}", hex::encode(&calldata))
            },
            "latest"
        ])).await?;

        let hex_result = claim_result.as_str().ok_or_else(|| anyhow!("Invalid result"))?;
        let bytes = hex::decode(hex_result.trim_start_matches("0x"))?;

        if bytes.len() < 128 {
            return Err(anyhow!("Invalid claim data"));
        }

        // Parse BisectionClaim struct
        let mut block_bytes = [0u8; 8];
        block_bytes.copy_from_slice(&bytes[24..32]);
        let block_number = u64::from_be_bytes(block_bytes);

        let mut trace_hash = [0u8; 32];
        trace_hash.copy_from_slice(&bytes[32..64]);

        Ok(BisectionClaim {
            block_number,
            trace_hash,
        })
    }

    /// Submit bisection response to L1
    async fn submit_bisection_response(&self, game_address: &str, agree: bool, mid_block: u64, trace_hash: Hash) -> Result<()> {
        // Call bisect(bool, uint64, bytes32)
        let selector = &tiny_keccak_hash(b"bisect(bool,uint64,bytes32)")[..4];
        
        let mut calldata = Vec::with_capacity(100);
        calldata.extend_from_slice(selector);
        
        // bool _agree (padded to 32 bytes)
        let mut agree_bytes = [0u8; 32];
        agree_bytes[31] = if agree { 1 } else { 0 };
        calldata.extend_from_slice(&agree_bytes);
        
        // uint64 _midBlock (padded to 32 bytes)
        let mut block_bytes = [0u8; 32];
        block_bytes[24..32].copy_from_slice(&mid_block.to_be_bytes());
        calldata.extend_from_slice(&block_bytes);
        
        // bytes32 _traceHash
        calldata.extend_from_slice(&trace_hash);

        let from_address = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"; // Anvil account 2

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
        
        // Wait for confirmation
        tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;

        Ok(())
    }

    /// Respond to proposer's bisection move
    pub async fn respond_bisection(
        &mut self,
        game_address: &str,
        proposer_block: u64,
        proposer_trace: Hash,
    ) -> Result<()> {
        let manager = self.active_games.get_mut(game_address)
            .ok_or_else(|| anyhow!("Game not found"))?;
        
        let response = manager.process_opponent_claim(proposer_block, proposer_trace);
        
        match response {
            BisectionResponse::Agree { our_mid_block, our_trace_hash: _ } => {
                info!("Agreeing with proposer, new claim at block {}", our_mid_block);
            }
            BisectionResponse::Disagree { our_mid_block, our_trace_hash: _ } => {
                info!("Disagreeing with proposer, new claim at block {}", our_mid_block);
            }
            BisectionResponse::Complete { disputed_block } => {
                info!("Bisection complete! Disputed block: {}", disputed_block);
            }
        }
        
        Ok(())
    }

    /// Update local state
    pub async fn update_state(&self, state: State, trace_log: TraceLog) {
        let mut s = self.state.write().await;
        *s = state;
        drop(s);

        let mut t = self.trace_log.write().await;
        *t = trace_log;
    }
}

/// Invalid batch info
#[derive(Debug, Clone)]
pub struct InvalidBatch {
    pub batch_index: u64,
    pub start_block: u64,
    pub end_block: u64,
    pub claimed_trace: Hash,
    pub our_trace: Hash,
}
