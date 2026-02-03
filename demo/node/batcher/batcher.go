// Package batcher implements the DEMO batcher service.
// Batcher collects transaction data and submits to L1.
package batcher

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/ethereum-optimism/optimism/demo/core/state"
	"github.com/ethereum-optimism/optimism/demo/core/types"
)

// BatchInfo is a simplified batch info for standalone batcher.
type BatchInfo struct {
	BatchIndex uint64
	TxDataHash types.Hash
	Data       []byte
}

// L1Client interface for L1 interactions.
type L1Client interface {
	SubmitBatchData(ctx context.Context, batchIndex uint64, txDataHash types.Hash, data []byte) error
}

// Config holds batcher configuration.
type Config struct {
	SubmitInterval time.Duration
	MaxBatchSize   int // Max bytes per submission
}

// DefaultConfig returns default batcher config.
func DefaultConfig() *Config {
	return &Config{
		SubmitInterval: 10 * time.Second, // Fast for demo
		MaxBatchSize:   120000,           // ~120KB per submission
	}
}

// Batcher collects and submits transaction data to L1.
type Batcher struct {
	config   *Config
	l1Client L1Client

	// Pending batches
	pendingBatches []*state.Batch
	pendingMux     sync.RWMutex

	// Control
	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup

	// Metrics
	submittedCount uint64
}

// New creates a new batcher.
func New(config *Config, l1Client L1Client) *Batcher {
	if config == nil {
		config = DefaultConfig()
	}

	return &Batcher{
		config:         config,
		l1Client:       l1Client,
		pendingBatches: make([]*state.Batch, 0),
	}
}

// Start starts the batcher.
func (b *Batcher) Start(ctx context.Context) error {
	b.ctx, b.cancel = context.WithCancel(ctx)

	b.wg.Add(1)
	go b.submitLoop()

	return nil
}

// Stop stops the batcher.
func (b *Batcher) Stop() {
	if b.cancel != nil {
		b.cancel()
	}
	b.wg.Wait()
}

// submitLoop periodically submits batches to L1.
func (b *Batcher) submitLoop() {
	defer b.wg.Done()

	ticker := time.NewTicker(b.config.SubmitInterval)
	defer ticker.Stop()

	for {
		select {
		case <-b.ctx.Done():
			return
		case <-ticker.C:
			b.submitPendingBatches()
		}
	}
}

// submitPendingBatches submits all pending batches.
func (b *Batcher) submitPendingBatches() {
	b.pendingMux.Lock()
	batches := b.pendingBatches
	b.pendingBatches = make([]*state.Batch, 0)
	b.pendingMux.Unlock()

	for _, batch := range batches {
		if err := b.submitBatch(batch); err != nil {
			// Re-add failed batch
			b.pendingMux.Lock()
			b.pendingBatches = append([]*state.Batch{batch}, b.pendingBatches...)
			b.pendingMux.Unlock()
			return
		}
	}
}

// submitBatch submits a single batch to L1.
func (b *Batcher) submitBatch(batch *state.Batch) error {
	// Serialize batch transaction data
	data, err := batch.Serialize()
	if err != nil {
		log.Printf("[Batcher] Failed to serialize batch %d: %v", batch.BatchIndex, err)
		return err
	}

	log.Printf("[Batcher] Submitting batch %d (txDataHash=%x, size=%d bytes)",
		batch.BatchIndex, batch.TxDataHash[:8], len(data))

	// Submit to L1
	if b.l1Client != nil {
		if err := b.l1Client.SubmitBatchData(b.ctx, batch.BatchIndex, batch.TxDataHash, data); err != nil {
			log.Printf("[Batcher] Failed to submit batch %d to L1: %v", batch.BatchIndex, err)
			return err
		}
		log.Printf("[Batcher] ✓ Batch %d submitted to L1", batch.BatchIndex)
	} else {
		log.Printf("[Batcher] ✓ Batch %d processed (no L1 client)", batch.BatchIndex)
	}

	b.submittedCount++
	return nil
}

// AddBatch adds a batch to the pending queue.
func (b *Batcher) AddBatch(batch *state.Batch) {
	b.pendingMux.Lock()
	defer b.pendingMux.Unlock()

	b.pendingBatches = append(b.pendingBatches, batch)
}

// PendingCount returns the number of pending batches.
func (b *Batcher) PendingCount() int {
	b.pendingMux.RLock()
	defer b.pendingMux.RUnlock()
	return len(b.pendingBatches)
}

// SubmittedCount returns the number of submitted batches.
func (b *Batcher) SubmittedCount() uint64 {
	return b.submittedCount
}

// ForceSubmit forces immediate submission of pending batches.
func (b *Batcher) ForceSubmit() {
	b.submitPendingBatches()
}
