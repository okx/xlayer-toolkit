// Package rpc implements the RPC backend.
package rpc

import (
	"fmt"
	"math/big"

	"github.com/ethereum-optimism/optimism/demo/core/block"
	"github.com/ethereum-optimism/optimism/demo/core/state"
	"github.com/ethereum-optimism/optimism/demo/core/tx"
	"github.com/ethereum-optimism/optimism/demo/core/types"
	"github.com/ethereum-optimism/optimism/demo/node/sequencer"
)

// SequencerBackend implements the Backend interface using Sequencer.
type SequencerBackend struct {
	seq *sequencer.Sequencer
}

// NewSequencerBackend creates a new SequencerBackend.
func NewSequencerBackend(seq *sequencer.Sequencer) *SequencerBackend {
	return &SequencerBackend{seq: seq}
}

// GetState returns the current state.
func (b *SequencerBackend) GetState() *state.State {
	return b.seq.GetState()
}

// GetBalance returns the balance of an address for a token.
func (b *SequencerBackend) GetBalance(addr types.Address, token types.TokenID) *big.Int {
	s := b.seq.GetState()
	acc := s.GetAccount(addr)
	if acc == nil {
		return big.NewInt(0)
	}
	return acc.GetBalance(token)
}

// GetAccount returns account information.
func (b *SequencerBackend) GetAccount(addr types.Address) *AccountInfo {
	s := b.seq.GetState()
	acc := s.GetAccount(addr)
	if acc == nil {
		return nil
	}

	balances := make(map[string]string)
	for tokenID, balance := range acc.Balances {
		balances[fmt.Sprintf("0x%x", tokenID)] = balance.String()
	}

	return &AccountInfo{
		Address:  fmt.Sprintf("0x%x", addr),
		Nonce:    acc.Nonce,
		Balances: balances,
	}
}

// GetPool returns pool information.
func (b *SequencerBackend) GetPool(tokenA, tokenB types.TokenID) *PoolInfo {
	s := b.seq.GetState()
	pool := s.GetPoolByTokens(tokenA, tokenB)
	if pool == nil {
		return nil
	}

	return &PoolInfo{
		PoolID:   fmt.Sprintf("0x%x", pool.ID),
		TokenA:   fmt.Sprintf("0x%x", pool.TokenA),
		TokenB:   fmt.Sprintf("0x%x", pool.TokenB),
		ReserveA: pool.ReserveA.String(),
		ReserveB: pool.ReserveB.String(),
		TotalLP:  pool.TotalLP.String(),
		FeeRate:  pool.FeeRate,
	}
}

// GetLatestBlock returns the latest block.
func (b *SequencerBackend) GetLatestBlock() *block.Block {
	return b.seq.GetLatestBlock()
}

// GetBlockByNumber returns a block by number.
func (b *SequencerBackend) GetBlockByNumber(num uint64) *block.Block {
	return b.seq.GetBlock(num)
}

// SubmitTx submits a transaction.
func (b *SequencerBackend) SubmitTx(transaction *tx.Transaction) error {
	return b.seq.SubmitTx(transaction)
}

// GetPendingTxCount returns the number of pending transactions.
func (b *SequencerBackend) GetPendingTxCount() int {
	return b.seq.PendingTxCount()
}

// GetCurrentBatch returns the current batch.
func (b *SequencerBackend) GetCurrentBatch() *state.Batch {
	return b.seq.CurrentBatch()
}

// GetCompletedBatches returns completed batches from the given index.
func (b *SequencerBackend) GetCompletedBatches(fromIndex uint64) []*state.Batch {
	return b.seq.GetCompletedBatches(fromIndex)
}

// GetBatchByIndex returns a batch by index.
func (b *SequencerBackend) GetBatchByIndex(index uint64) *state.Batch {
	return b.seq.GetBatchByIndex(index)
}

// Ensure SequencerBackend implements Backend
var _ Backend = (*SequencerBackend)(nil)
