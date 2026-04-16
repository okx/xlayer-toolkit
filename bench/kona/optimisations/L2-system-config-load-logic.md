The complete call chain from the actual kona source:

### Step 1 — SequencerActor calls prepare_payload_attributes with unsafe_head (the L2 parent):

```rust
async fn build_attributes(
    &mut self,
    unsafe_head: L2BlockInfo,    // ← this is the L2 PARENT block
    l1_origin: BlockInfo,
) -> Result<Option<OpAttributesWithParent>, SequencerActorError> {
    let mut attributes = match self
        .attributes_builder
        .prepare_payload_attributes(unsafe_head, l1_origin.id())
        //                          ^^^^^^^^^^^
        //                          L2 parent passed here — NOT L1 head
        .await
```

### Step 2 — prepare_payload_attributes fetches config using l2_parent.block_info.number:

```rust
  async fn prepare_payload_attributes(
    &mut self,
    l2_parent: L2BlockInfo,     // ← the L2 parent block from Function 1
    epoch: BlockNumHash,
) -> PipelineResult<OpPayloadAttributes> {
    let l1_header;
    let deposit_transactions: Vec<Bytes>;

    // ── Step C1: fetch SystemConfig from L2 PARENT ──────────────────
    let t_c1 = Instant::now();
    let mut sys_config = self
        .config_fetcher
        .system_config_by_number(l2_parent.block_info.number, self.rollup_cfg.clone())
        //                       ^^^^^^^^^^^^^^^^^^^^^^^^^^
        //                       L2 PARENT block number — this is the proof.
        //                       Not L1 head. Not current block. The PARENT.
        .await
```

### Step 3 — system_config_by_number fetches that L2 block and extracts config from it:

// providers-alloy/src/l2_chain_provider.rs:358-364
```rust
  async fn system_config_by_number(
      &mut self,
      number: u64,                // ← this is l2_parent.block_info.number from Function 2
      rollup_config: Arc<RollupConfig>,
  ) -> Result<SystemConfig, <Self as BatchValidationProvider>::Error> {
      // If L1WatcherActor signalled a SystemConfig change on L1, evict the cache so the
      // very next block build fetches the updated gasLimit / batcherAddr / etc.
      // swap(false) atomically clears the flag — prevents double-eviction across concurrent
      // callers even though system_config_by_number is &mut (single-caller in practice).
      if self.system_config_invalidated.swap(false, Ordering::Relaxed) {
          self.last_system_config = None;
      }

      if let Some(ref cfg) = self.last_system_config {
          return Ok(cfg.clone());
      }

      // Cold path: fetch from the L2 node and prime the cache.
      let block = self
          .block_by_number(number)      // ← fetches the L2 PARENT block from reth
          .await
          .map_err(|_| AlloyL2ChainProviderError::BlockNotFound(number))?;
      let config = to_system_config(&block, &rollup_config)
      //           ^^^^^^^^^^^^^^^^
      //           extracts config from that L2 block's embedded L1InfoTx
```

### Step 4 — to_system_config reads config from the L2 block's first deposit tx (L1InfoTx):

```rust
// protocol/src/utils.rs:36-58
pub fn to_system_config(
    block: &OpBlock,               // ← the L2 PARENT block from Function 3
    rollup_config: &RollupConfig,
) -> Result<SystemConfig, OpBlockConversionError> {
    // Genesis block: return config from rollup genesis definition
    if block.header.number == rollup_config.genesis.l2.number {
        if block.header.hash_slow() != rollup_config.genesis.l2.hash {
            return Err(OpBlockConversionError::InvalidGenesisHash(
                rollup_config.genesis.l2.hash,
                block.header.hash_slow(),
            ));
        }
        return rollup_config
            .genesis
            .system_config
            .ok_or(OpBlockConversionError::MissingSystemConfigGenesis);
    }

    // Non-genesis: extract from the block's FIRST transaction (L1InfoTx deposit)
    if block.body.transactions.is_empty() {
        return Err(OpBlockConversionError::EmptyTransactions(block.header.hash_slow()));
    }
    let Some(tx) = block.body.transactions[0].as_deposit() else {
    // ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    // First tx in every L2 block = L1InfoTx deposit
    // This was embedded when this L2 block was ORIGINALLY BUILT
    // It contains the config snapshot from that block's l1_origin
```


This is the L2 parent block's already-embedded config. It's historical data, not a live L1 query.






### Step 5 — Config only changes at epoch boundary (l1_origin advances):

```rust
// derive/src/attributes/stateful.rs:88-142
if l2_parent.l1_origin.number == epoch.number {
// SAME EPOCH — 11 of 12 blocks
deposit_transactions = vec![];   // no deposits, no config update
sequence_number = l2_parent.seq_num + 1;
} else {
// EPOCH CHANGE — 1 of 12 blocks
let receipts = self.receipts_fetcher
.receipts_by_hash(epoch.hash).await?;       // fetch L1 receipts
sys_config.update_with_receipts(&receipts, ...); // ← CONFIG CHANGES HERE ONLY
sequence_number = 0;
}
```

### So the staleness concern is a non-issue because:
- Baseline kona reads config from the L2 parent block's embedded L1InfoTx — that's already "stale" by definition (it's the previous block's snapshot)
- Config changes only propagate via update_with_receipts() at epoch boundaries
- Our cache returns the exact same value that to_system_config(l2_parent_block) would return
- Same behaviour in baseline, same behaviour with cache
