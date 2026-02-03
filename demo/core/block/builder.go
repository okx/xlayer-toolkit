// Package block implements block building.
package block

import (
	"time"

	"github.com/ethereum-optimism/optimism/demo/core/tx"
	"github.com/ethereum-optimism/optimism/demo/core/types"
)

// StateInterface defines the interface for state operations.
type StateInterface interface {
	Clone() StateInterface
	StateHash() types.Hash
	ComputeIncrementalHash(changes []StateChange) types.Hash
}

// StateChange represents a single state change.
// Duplicated here to avoid import cycle.
type StateChange struct {
	Type    StateChangeType
	Key     []byte
	OldData []byte
	NewData []byte
}

// StateChangeType represents the type of state change.
type StateChangeType uint8

const (
	ChangeTypeAccount StateChangeType = 1
	ChangeTypeToken   StateChangeType = 2
	ChangeTypePool    StateChangeType = 3
)

// ExecutorInterface defines the interface for transaction execution.
type ExecutorInterface interface {
	Execute(s interface{}, tx *tx.Transaction) *ExecuteResult
}

// ExecuteResult represents the result of executing a transaction.
type ExecuteResult struct {
	Success bool
	Error   error
	Changes []StateChange
}

// Builder builds blocks by executing transactions.
type Builder struct{}

// NewBuilder creates a new block builder.
func NewBuilder() *Builder {
	return &Builder{}
}

// BuildResult represents the result of building a block.
type BuildResult struct {
	Block          *Block
	ExecutedTxs    []*tx.Transaction
	FailedTxs      []*tx.Transaction
	TotalChanges   []StateChange
	FinalStateHash types.Hash
}

// BuildBlock builds a block header with the given parameters.
func (b *Builder) BuildBlock(
	parentBlock *Block,
	stateHash types.Hash,
	txs []*tx.Transaction,
	proposer types.Address,
) *Block {
	// Calculate transactions root
	txRoot := CalculateTransactionsRoot(txs)

	// Create block header
	header := Header{
		Number:           parentBlock.Number() + 1,
		ParentHash:       parentBlock.Hash(),
		StateHash:        stateHash,
		TransactionsRoot: txRoot,
		Timestamp:        uint64(time.Now().Unix()),
		Proposer:         proposer,
	}

	return NewBlock(header, txs)
}

// ValidateBlockHeader validates a block header against the parent.
func (b *Builder) ValidateBlockHeader(block *Block, parentBlock *Block) error {
	// Check block number
	if block.Number() != parentBlock.Number()+1 {
		return types.ErrInvalidBlockNumber
	}

	// Check parent hash
	if block.ParentHash() != parentBlock.Hash() {
		return types.ErrInvalidParentHash
	}

	return nil
}
