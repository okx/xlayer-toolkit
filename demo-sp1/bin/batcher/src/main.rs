//! Batcher - Batch L2 block data and submit to L1 BatchInbox
//!
//! The Batcher compresses and submits L2 block data to L1 for data availability.
//! This is separate from the Proposer which submits state commitments (state_root, trace_hash).

use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use std::env;
use std::time::Duration;
use tiny_keccak::{Hasher, Keccak};
use tokio::time::sleep;
use tracing::{info, warn, error};

/// Batcher configuration
#[derive(Debug, Clone)]
struct BatcherConfig {
    /// L1 RPC endpoint
    l1_rpc: String,
    /// L2 RPC endpoint
    l2_rpc: String,
    /// BatchInbox contract address on L1
    batch_inbox: String,
    /// Batcher private key or address
    batcher_address: String,
    /// Batch submission interval in seconds
    batch_interval: u64,
    /// Maximum batch size in bytes
    max_batch_size: usize,
}

impl BatcherConfig {
    fn from_env() -> Self {
        Self {
            l1_rpc: env::var("L1_RPC").unwrap_or_else(|_| "http://anvil:8545".to_string()),
            l2_rpc: env::var("L2_RPC").unwrap_or_else(|_| "http://node:8546".to_string()),
            batch_inbox: env::var("BATCH_INBOX_ADDRESS").unwrap_or_default(),
            batcher_address: env::var("BATCHER_ADDRESS")
                .unwrap_or_else(|_| "0x90F79bf6EB2c4f870365E785982E1f101E93b906".to_string()), // Anvil account 3
            batch_interval: env::var("BATCH_INTERVAL")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(30),
            max_batch_size: env::var("MAX_BATCH_SIZE")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(120_000), // ~120KB default
        }
    }
}

/// Block data from L2 node
#[derive(Debug, Clone, Serialize, Deserialize)]
struct BlockData {
    number: u64,
    hash: String,
    parent_hash: String,
    timestamp: u64,
    transactions: Vec<TxData>,
}

/// Transaction data
#[derive(Debug, Clone, Serialize, Deserialize)]
struct TxData {
    hash: String,
    from: String,
    to: String,
    value: String,
    data: String,
}

/// Compressed batch data
#[derive(Debug, Clone, Serialize)]
struct CompressedBatch {
    version: u8,
    start_block: u64,
    end_block: u64,
    block_count: u64,
    /// Compressed block data
    data: Vec<u8>,
    /// Hash of uncompressed data
    data_hash: [u8; 32],
}

/// Batcher state
struct Batcher {
    config: BatcherConfig,
    http_client: reqwest::Client,
    /// Last submitted block number
    last_submitted_block: u64,
    /// Pending blocks to batch
    pending_blocks: Vec<BlockData>,
}

impl Batcher {
    fn new(config: BatcherConfig) -> Self {
        Self {
            config,
            http_client: reqwest::Client::new(),
            last_submitted_block: 0,
            pending_blocks: vec![],
        }
    }

    /// Run the batcher loop
    async fn run(&mut self) -> Result<()> {
        info!("Starting Batcher...");
        info!("  L1 RPC: {}", self.config.l1_rpc);
        info!("  L2 RPC: {}", self.config.l2_rpc);
        info!("  Batch Inbox: {}", self.config.batch_inbox);
        info!("  Interval: {}s", self.config.batch_interval);

        loop {
            if let Err(e) = self.sync_and_submit().await {
                error!("Batcher error: {}", e);
            }

            sleep(Duration::from_secs(self.config.batch_interval)).await;
        }
    }

    /// Sync new blocks from L2 and submit batch if ready
    async fn sync_and_submit(&mut self) -> Result<()> {
        // Get latest L2 block
        let l2_height = self.get_l2_block_number().await?;
        
        if l2_height <= self.last_submitted_block {
            info!("No new blocks to batch (L2 height: {}, last submitted: {})", 
                  l2_height, self.last_submitted_block);
            return Ok(());
        }

        // Fetch new blocks
        let start = self.last_submitted_block + 1;
        let end = l2_height;
        
        info!("Fetching blocks {} - {}", start, end);

        for block_num in start..=end {
            match self.get_l2_block(block_num).await {
                Ok(block) => {
                    self.pending_blocks.push(block);
                }
                Err(e) => {
                    warn!("Failed to fetch block {}: {}", block_num, e);
                    break;
                }
            }
        }

        // Check if we should submit a batch
        if self.should_submit_batch() {
            self.submit_batch().await?;
        }

        Ok(())
    }

    /// Check if we should submit a batch
    fn should_submit_batch(&self) -> bool {
        if self.pending_blocks.is_empty() {
            return false;
        }

        // Submit if we have enough blocks or data
        let estimated_size = self.estimate_batch_size();
        let block_count = self.pending_blocks.len();

        // Submit if:
        // - 100+ blocks accumulated
        // - Or data size exceeds max
        block_count >= 100 || estimated_size >= self.config.max_batch_size
    }

    /// Estimate batch size in bytes
    fn estimate_batch_size(&self) -> usize {
        // Rough estimate: ~100 bytes per tx
        self.pending_blocks.iter()
            .map(|b| 100 + b.transactions.len() * 100)
            .sum()
    }

    /// Submit a batch to L1 BatchInbox
    async fn submit_batch(&mut self) -> Result<()> {
        if self.pending_blocks.is_empty() {
            return Ok(());
        }

        let start_block = self.pending_blocks.first().map(|b| b.number).unwrap_or(0);
        let end_block = self.pending_blocks.last().map(|b| b.number).unwrap_or(0);
        
        info!("Submitting batch: blocks {} - {}", start_block, end_block);

        // Compress batch data
        let batch = self.compress_batch()?;
        
        info!("  Compressed size: {} bytes", batch.data.len());
        info!("  Data hash: 0x{}", hex::encode(batch.data_hash));

        // Submit to L1
        if self.config.batch_inbox.is_empty() {
            // No BatchInbox configured - just log
            info!("  (No BatchInbox configured - skipping L1 submission)");
        } else {
            self.submit_to_l1(&batch).await?;
        }

        // Update state
        self.last_submitted_block = end_block;
        self.pending_blocks.clear();

        info!("✓ Batch submitted successfully!");

        Ok(())
    }

    /// Compress pending blocks into a batch
    fn compress_batch(&self) -> Result<CompressedBatch> {
        let start_block = self.pending_blocks.first().map(|b| b.number).unwrap_or(0);
        let end_block = self.pending_blocks.last().map(|b| b.number).unwrap_or(0);

        // Serialize blocks
        let block_data = serde_json::to_vec(&self.pending_blocks)?;
        
        // Compute hash of uncompressed data
        let data_hash = keccak256(&block_data);

        // Simple compression: just use the JSON for now
        // In production, use zlib/zstd compression
        let compressed = block_data.clone();

        Ok(CompressedBatch {
            version: 1,
            start_block,
            end_block,
            block_count: self.pending_blocks.len() as u64,
            data: compressed,
            data_hash,
        })
    }

    /// Submit batch data to L1 BatchInbox
    async fn submit_to_l1(&self, batch: &CompressedBatch) -> Result<()> {
        // Encode batch for submission
        // Format: version (1 byte) || start_block (8 bytes) || end_block (8 bytes) || data_hash (32 bytes) || data
        let mut calldata = Vec::new();
        calldata.push(batch.version);
        calldata.extend_from_slice(&batch.start_block.to_be_bytes());
        calldata.extend_from_slice(&batch.end_block.to_be_bytes());
        calldata.extend_from_slice(&batch.data_hash);
        calldata.extend_from_slice(&batch.data);

        let tx_request = serde_json::json!({
            "from": self.config.batcher_address,
            "to": self.config.batch_inbox,
            "data": format!("0x{}", hex::encode(&calldata)),
            "gas": "0x1000000" // 16M gas for large batches
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
            return Err(anyhow!("Failed to submit batch: {:?}", error));
        }

        let tx_hash = response.get("result")
            .and_then(|r| r.as_str())
            .ok_or_else(|| anyhow!("No tx hash in response"))?;

        info!("  tx_hash: {}", tx_hash);

        // Wait for confirmation
        sleep(Duration::from_secs(2)).await;

        Ok(())
    }

    /// Get L2 block number
    async fn get_l2_block_number(&self) -> Result<u64> {
        let result = self.rpc_call(&self.config.l2_rpc, "x2_blockNumber", serde_json::json!([])).await?;
        
        // Node returns hex string like "0x64"
        let block_num = if let Some(num) = result.as_u64() {
            num
        } else if let Some(hex_str) = result.as_str() {
            let hex_str = hex_str.trim_start_matches("0x");
            u64::from_str_radix(hex_str, 16)
                .map_err(|_| anyhow!("Invalid hex block number: {}", result))?
        } else {
            return Err(anyhow!("Invalid block number format: {}", result));
        };

        Ok(block_num)
    }

    /// Get L2 block by number
    async fn get_l2_block(&self, number: u64) -> Result<BlockData> {
        let result = self.rpc_call(&self.config.l2_rpc, "x2_getBlock", serde_json::json!([number])).await?;
        
        // Parse block data from RPC response
        let block = BlockData {
            number: result.get("number").and_then(|n| n.as_u64()).unwrap_or(number),
            hash: result.get("hash").and_then(|h| h.as_str()).unwrap_or_default().to_string(),
            parent_hash: result.get("parentHash").and_then(|h| h.as_str()).unwrap_or_default().to_string(),
            timestamp: result.get("timestamp").and_then(|t| t.as_u64()).unwrap_or(0),
            transactions: vec![], // Simplified - not fetching full tx data
        };

        Ok(block)
    }

    /// Make RPC call
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
            .ok_or_else(|| {
                let error = response.get("error");
                anyhow!("RPC error: {:?}", error)
            })
    }
}

/// Compute keccak256 hash
fn keccak256(data: &[u8]) -> [u8; 32] {
    let mut hasher = Keccak::v256();
    hasher.update(data);
    let mut output = [0u8; 32];
    hasher.finalize(&mut output);
    output
}

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize tracing
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive(tracing::Level::INFO.into()),
        )
        .init();

    info!("===========================================");
    info!("        XLayer DEX Batcher");
    info!("===========================================");

    let config = BatcherConfig::from_env();
    let mut batcher = Batcher::new(config);

    batcher.run().await
}
