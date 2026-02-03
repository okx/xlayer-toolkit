// Package block implements block structures and block production.
package block

import (
	"bytes"
	"encoding/gob"
	"time"

	"github.com/ethereum-optimism/optimism/demo/core/tx"
	"github.com/ethereum-optimism/optimism/demo/core/types"
)

// Header represents a block header.
type Header struct {
	Number           uint64
	ParentHash       types.Hash
	StateHash        types.Hash // Incremental state hash after execution
	TransactionsRoot types.Hash // Merkle root of transactions
	Timestamp        uint64
	Proposer         types.Address
}

// Hash returns the hash of the header.
func (h *Header) Hash() types.Hash {
	var buf bytes.Buffer
	buf.Write(types.Uint64ToBytes(h.Number))
	buf.Write(h.ParentHash[:])
	buf.Write(h.StateHash[:])
	buf.Write(h.TransactionsRoot[:])
	buf.Write(types.Uint64ToBytes(h.Timestamp))
	buf.Write(h.Proposer[:])
	return types.Keccak256(buf.Bytes())
}

// Block represents a block in demo.
type Block struct {
	Header       Header
	Transactions []*tx.Transaction
}

// NewBlock creates a new block.
func NewBlock(header Header, txs []*tx.Transaction) *Block {
	return &Block{
		Header:       header,
		Transactions: txs,
	}
}

// Hash returns the hash of the block (same as header hash).
func (b *Block) Hash() types.Hash {
	return b.Header.Hash()
}

// Number returns the block number.
func (b *Block) Number() uint64 {
	return b.Header.Number
}

// ParentHash returns the parent block hash.
func (b *Block) ParentHash() types.Hash {
	return b.Header.ParentHash
}

// StateHash returns the state hash after executing this block.
func (b *Block) StateHash() types.Hash {
	return b.Header.StateHash
}

// CalculateTransactionsRoot calculates the Merkle root of transactions.
func CalculateTransactionsRoot(txs []*tx.Transaction) types.Hash {
	if len(txs) == 0 {
		return types.ZeroHash
	}

	// Simple implementation: hash all transaction hashes together
	// In production, use proper Merkle tree
	hashes := make([][]byte, len(txs))
	for i, tx := range txs {
		h := tx.Hash()
		hashes[i] = h[:]
	}

	return merkleRoot(hashes)
}

// merkleRoot computes a simple Merkle root.
func merkleRoot(data [][]byte) types.Hash {
	if len(data) == 0 {
		return types.ZeroHash
	}
	if len(data) == 1 {
		return types.BytesToHash(data[0])
	}

	// Pad to even length
	if len(data)%2 == 1 {
		data = append(data, data[len(data)-1])
	}

	// Compute next level
	nextLevel := make([][]byte, len(data)/2)
	for i := 0; i < len(data)/2; i++ {
		combined := append(data[i*2], data[i*2+1]...)
		h := types.Keccak256(combined)
		nextLevel[i] = h[:]
	}

	return merkleRoot(nextLevel)
}

// Serialize serializes the block to bytes.
func (b *Block) Serialize() ([]byte, error) {
	var buf bytes.Buffer
	enc := gob.NewEncoder(&buf)
	if err := enc.Encode(b); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// DeserializeBlock deserializes bytes to a block.
func DeserializeBlock(data []byte) (*Block, error) {
	var b Block
	dec := gob.NewDecoder(bytes.NewReader(data))
	if err := dec.Decode(&b); err != nil {
		return nil, err
	}
	return &b, nil
}

// GenesisBlock creates the genesis block.
func GenesisBlock() *Block {
	return &Block{
		Header: Header{
			Number:           0,
			ParentHash:       types.ZeroHash,
			StateHash:        types.ZeroHash,
			TransactionsRoot: types.ZeroHash,
			Timestamp:        uint64(time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC).Unix()),
			Proposer:         types.ZeroAddress,
		},
		Transactions: nil,
	}
}
