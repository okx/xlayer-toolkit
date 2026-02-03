// Package sequencer implements the DEMO sequencer service.
package sequencer

import (
	"context"
	"math/big"
	"sync"
	"time"

	"github.com/ethereum-optimism/optimism/demo/core/block"
	"github.com/ethereum-optimism/optimism/demo/core/state"
	"github.com/ethereum-optimism/optimism/demo/core/tx"
	"github.com/ethereum-optimism/optimism/demo/core/types"
)

// Config holds sequencer configuration.
type Config struct {
	BlockTime       time.Duration // Time between blocks
	MaxBlockTxs     int           // Max transactions per block
	Proposer        types.Address // Sequencer address
	BatchSize       int           // Number of blocks per batch
	BatchSubmitTime time.Duration // Time between batch submissions
}

// DefaultConfig returns default sequencer config.
func DefaultConfig() *Config {
	return &Config{
		BlockTime:       2 * time.Second,
		MaxBlockTxs:     1000,
		Proposer:        types.Address{0x01},
		BatchSize:       100,
		BatchSubmitTime: 5 * time.Minute,
	}
}

// Sequencer produces blocks and manages the chain.
type Sequencer struct {
	config *Config

	// State
	state       *state.State
	latestBlock *block.Block
	blockNum    uint64

	// Transaction pool
	txPool    []*tx.Transaction
	txPoolMux sync.RWMutex

	// Block production
	builder  *block.Builder
	executor *tx.Executor

	// Batch management
	currentBatch     *state.Batch
	completedBatches []*state.Batch
	batchNum         uint64
	batchMux         sync.RWMutex

	// Callbacks
	onNewBlock func(*block.Block)
	onNewBatch func(*state.Batch)

	// Control
	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup
}

// New creates a new sequencer.
func New(config *Config) *Sequencer {
	if config == nil {
		config = DefaultConfig()
	}

	s := &Sequencer{
		config:      config,
		state:       state.NewState(),
		latestBlock: block.GenesisBlock(),
		blockNum:    0,
		txPool:      make([]*tx.Transaction, 0),
		builder:     block.NewBuilder(),
		executor:    tx.NewExecutor(),
		batchNum:    0,
	}

	// Initialize first batch
	s.currentBatch = state.NewBatch(0, 1, 0, s.state.StateHash())

	return s
}

// Start starts the sequencer.
func (s *Sequencer) Start(ctx context.Context) error {
	s.ctx, s.cancel = context.WithCancel(ctx)

	s.wg.Add(1)
	go s.blockProductionLoop()

	return nil
}

// Stop stops the sequencer.
func (s *Sequencer) Stop() {
	if s.cancel != nil {
		s.cancel()
	}
	s.wg.Wait()
}

// blockProductionLoop produces blocks periodically.
func (s *Sequencer) blockProductionLoop() {
	defer s.wg.Done()

	ticker := time.NewTicker(s.config.BlockTime)
	defer ticker.Stop()

	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			s.produceBlock()
		}
	}
}

// produceBlock produces a new block.
func (s *Sequencer) produceBlock() {
	s.txPoolMux.Lock()

	// Get transactions from pool
	txs := s.txPool
	if len(txs) > s.config.MaxBlockTxs {
		txs = txs[:s.config.MaxBlockTxs]
	}

	// Clear used transactions
	if len(txs) > 0 {
		s.txPool = s.txPool[len(txs):]
	}
	s.txPoolMux.Unlock()

	// Execute transactions
	executedTxs := make([]*tx.Transaction, 0)
	allChanges := make([]state.StateChange, 0)

	for _, transaction := range txs {
		result := s.executor.Execute(s.state, transaction)
		if result.Success {
			executedTxs = append(executedTxs, transaction)
			// Convert changes
			for _, c := range result.Changes {
				allChanges = append(allChanges, state.StateChange{
					Type: state.StateChangeType(c.Type),
					Key:  c.Key,
				})
			}
		}
	}

	// Compute new state hash
	// Even if no changes, include block info to ensure non-zero hash
	var newStateHash types.Hash
	if len(allChanges) > 0 {
		newStateHash = s.state.ComputeIncrementalHash(allChanges)
	} else {
		// No changes - compute hash based on block info
		prevHash := s.state.StateHash()
		blockInfo := append(types.Uint64ToBytes(s.blockNum+1), types.Uint64ToBytes(uint64(time.Now().UnixNano()))...)
		newStateHash = types.Keccak256(prevHash[:], blockInfo)
		s.state.SetStateHash(newStateHash)
	}

	// Build block
	newBlock := s.builder.BuildBlock(s.latestBlock, newStateHash, executedTxs, s.config.Proposer)

	// Update state
	s.latestBlock = newBlock
	s.blockNum = newBlock.Number()

	// Add block to current batch
	txHashes := make([]types.Hash, len(executedTxs))
	for i, t := range executedTxs {
		txHashes[i] = t.Hash()
	}
	s.currentBatch.AddBlockData(state.BlockData{
		Number:    newBlock.Number(),
		Hash:      newBlock.Hash(),
		StateHash: newBlock.StateHash(),
		TxHashes:  txHashes,
	})

	// Check if batch is full
	blocksInBatch := len(s.currentBatch.Blocks)
	if blocksInBatch >= s.config.BatchSize {
		s.finalizeBatch()
	}

	// Notify callback
	if s.onNewBlock != nil {
		s.onNewBlock(newBlock)
	}
}

// finalizeBatch finalizes the current batch and starts a new one.
func (s *Sequencer) finalizeBatch() {
	s.batchMux.Lock()
	defer s.batchMux.Unlock()

	if len(s.currentBatch.Blocks) == 0 {
		return
	}

	// Compute transaction data hash
	s.currentBatch.ComputeTxDataHash()

	// Create verifiable state for MPT
	vs := state.NewVerifiableStateFromState(s.state)

	// Finalize batch with MPT root
	s.currentBatch.Finalize(s.state.StateHash(), vs.MPTRoot())

	// Store completed batch
	s.completedBatches = append(s.completedBatches, s.currentBatch)

	// Notify callback
	if s.onNewBatch != nil {
		s.onNewBatch(s.currentBatch)
	}

	// Start new batch
	s.batchNum++
	s.currentBatch = state.NewBatch(
		s.batchNum,
		s.blockNum+1,
		0,
		s.state.StateHash(),
	)
}

// SubmitTx submits a transaction to the pool.
func (s *Sequencer) SubmitTx(transaction *tx.Transaction) error {
	s.txPoolMux.Lock()
	defer s.txPoolMux.Unlock()

	s.txPool = append(s.txPool, transaction)
	return nil
}

// GetState returns the current state.
func (s *Sequencer) GetState() *state.State {
	return s.state.Clone()
}

// GetLatestBlock returns the latest block.
func (s *Sequencer) GetLatestBlock() *block.Block {
	return s.latestBlock
}

// GetBlock returns a block by number.
func (s *Sequencer) GetBlock(num uint64) *block.Block {
	// In production, this would query a database
	// For MVP, we only track the latest block
	if num == s.latestBlock.Number() {
		return s.latestBlock
	}
	return nil
}

// SetOnNewBlock sets the callback for new blocks.
func (s *Sequencer) SetOnNewBlock(fn func(*block.Block)) {
	s.onNewBlock = fn
}

// SetOnNewBatch sets the callback for new batches.
func (s *Sequencer) SetOnNewBatch(fn func(*state.Batch)) {
	s.onNewBatch = fn
}

// PendingTxCount returns the number of pending transactions.
func (s *Sequencer) PendingTxCount() int {
	s.txPoolMux.RLock()
	defer s.txPoolMux.RUnlock()
	return len(s.txPool)
}

// CurrentBatch returns the current batch being built.
func (s *Sequencer) CurrentBatch() *state.Batch {
	return s.currentBatch
}

// ForceBatch forces a batch to be finalized.
func (s *Sequencer) ForceBatch() {
	s.finalizeBatch()
}

// InitializeAccount initializes an account with balances (for testing).
func (s *Sequencer) InitializeAccount(addr types.Address, balances map[types.TokenID]*big.Int) {
	acc := s.state.GetOrCreateAccount(addr)
	for token, amount := range balances {
		acc.AddBalance(token, amount)
	}
}

// GetCompletedBatches returns all completed batches from the given index.
func (s *Sequencer) GetCompletedBatches(fromIndex uint64) []*state.Batch {
	s.batchMux.RLock()
	defer s.batchMux.RUnlock()

	var result []*state.Batch
	for _, batch := range s.completedBatches {
		if batch.BatchIndex >= fromIndex {
			result = append(result, batch)
		}
	}
	return result
}

// GetBatchByIndex returns a completed batch by index.
func (s *Sequencer) GetBatchByIndex(index uint64) *state.Batch {
	s.batchMux.RLock()
	defer s.batchMux.RUnlock()

	for _, batch := range s.completedBatches {
		if batch.BatchIndex == index {
			return batch
		}
	}
	return nil
}

// CompletedBatchCount returns the number of completed batches.
func (s *Sequencer) CompletedBatchCount() int {
	s.batchMux.RLock()
	defer s.batchMux.RUnlock()
	return len(s.completedBatches)
}
