// Package state implements batch-related state operations.
package state

import (
	"bytes"
	"encoding/gob"

	"github.com/ethereum-optimism/optimism/demo/core/mpt"
	"github.com/ethereum-optimism/optimism/demo/core/types"
)

// BlockData represents essential block data for batch.
// This avoids circular import with block package.
type BlockData struct {
	Number    uint64
	Hash      types.Hash
	StateHash types.Hash
	TxHashes  []types.Hash
}

// Batch represents a batch of blocks to be submitted to L1.
type Batch struct {
	BatchIndex     uint64
	StartBlock     uint64
	EndBlock       uint64
	Blocks         []BlockData
	PrevStateHash  types.Hash // State hash before this batch
	FinalStateHash types.Hash // Incremental state hash after all blocks
	MPTRoot        types.Hash // MPT root for verifiable state
	TxDataHash     types.Hash // Hash of all transaction data
}

// NewBatch creates a new batch.
func NewBatch(index, startBlock, endBlock uint64, prevStateHash types.Hash) *Batch {
	return &Batch{
		BatchIndex:    index,
		StartBlock:    startBlock,
		EndBlock:      endBlock,
		Blocks:        make([]BlockData, 0),
		PrevStateHash: prevStateHash,
	}
}

// AddBlockData adds block data to the batch.
func (b *Batch) AddBlockData(data BlockData) {
	b.Blocks = append(b.Blocks, data)
	if data.Number > b.EndBlock {
		b.EndBlock = data.Number
	}
}

// ComputeTxDataHash computes the hash of all transaction data in the batch.
func (b *Batch) ComputeTxDataHash() types.Hash {
	var buf bytes.Buffer

	for _, blk := range b.Blocks {
		for _, txHash := range blk.TxHashes {
			buf.Write(txHash[:])
		}
	}

	b.TxDataHash = types.Keccak256(buf.Bytes())
	return b.TxDataHash
}

// Finalize finalizes the batch with the final state hash and MPT root.
func (b *Batch) Finalize(finalStateHash, mptRoot types.Hash) {
	b.FinalStateHash = finalStateHash
	b.MPTRoot = mptRoot
}

// Serialize serializes the batch to bytes.
func (b *Batch) Serialize() ([]byte, error) {
	var buf bytes.Buffer
	enc := gob.NewEncoder(&buf)
	if err := enc.Encode(b); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// DeserializeBatch deserializes bytes to a batch.
func DeserializeBatch(data []byte) (*Batch, error) {
	var b Batch
	dec := gob.NewDecoder(bytes.NewReader(data))
	if err := dec.Decode(&b); err != nil {
		return nil, err
	}
	return &b, nil
}

// Output represents the output submitted to L1 by Proposer.
type Output struct {
	BatchIndex     uint64
	FinalStateHash types.Hash // Incremental state hash
	MPTRoot        types.Hash // MPT root for Cannon challenge
	Timestamp      uint64
}

// NewOutput creates a new output.
func NewOutput(batch *Batch, timestamp uint64) *Output {
	return &Output{
		BatchIndex:     batch.BatchIndex,
		FinalStateHash: batch.FinalStateHash,
		MPTRoot:        batch.MPTRoot,
		Timestamp:      timestamp,
	}
}

// Hash returns the hash of the output.
func (o *Output) Hash() types.Hash {
	var buf bytes.Buffer
	buf.Write(types.Uint64ToBytes(o.BatchIndex))
	buf.Write(o.FinalStateHash[:])
	buf.Write(o.MPTRoot[:])
	buf.Write(types.Uint64ToBytes(o.Timestamp))
	return types.Keccak256(buf.Bytes())
}

// VerifiableState wraps State with MPT for verifiable operations.
// Used in program for Cannon fault proofs.
type VerifiableState struct {
	*State
	mptTrie *mpt.Trie
}

// NewVerifiableState creates a new verifiable state.
func NewVerifiableState() *VerifiableState {
	vs := &VerifiableState{
		State:   NewState(),
		mptTrie: mpt.New(),
	}
	// Insert genesis marker to ensure non-zero root
	vs.mptTrie.Insert([]byte("genesis"), []byte("demo-genesis-v1"))
	return vs
}

// NewVerifiableStateFromState creates a verifiable state from existing state.
func NewVerifiableStateFromState(s *State) *VerifiableState {
	vs := &VerifiableState{
		State:   s,
		mptTrie: mpt.New(),
	}
	// Insert genesis marker to ensure non-zero root
	vs.mptTrie.Insert([]byte("genesis"), []byte("demo-genesis-v1"))
	// Rebuild MPT from state
	vs.rebuildMPT()
	return vs
}

// rebuildMPT rebuilds the MPT from current state.
func (vs *VerifiableState) rebuildMPT() {
	// Add all accounts to MPT
	for addr, acc := range vs.State.Accounts {
		key := addr[:]
		value := vs.serializeAccount(acc)
		vs.mptTrie.Insert(key, value)
	}

	// Add all pools to MPT
	for id, pool := range vs.State.Pools {
		key := append([]byte("pool:"), id[:]...)
		value := vs.serializePool(pool)
		vs.mptTrie.Insert(key, value)
	}
}

// serializeAccount serializes an account for MPT.
func (vs *VerifiableState) serializeAccount(acc interface{}) []byte {
	var buf bytes.Buffer
	enc := gob.NewEncoder(&buf)
	_ = enc.Encode(acc)
	return buf.Bytes()
}

// serializePool serializes a pool for MPT.
func (vs *VerifiableState) serializePool(pool interface{}) []byte {
	var buf bytes.Buffer
	enc := gob.NewEncoder(&buf)
	_ = enc.Encode(pool)
	return buf.Bytes()
}

// UpdateMPT updates the MPT with state changes.
func (vs *VerifiableState) UpdateMPT(changes []StateChange) {
	for _, change := range changes {
		switch change.Type {
		case ChangeTypeAccount:
			addr := types.BytesToAddress(change.Key)
			if acc := vs.State.GetAccount(addr); acc != nil {
				vs.mptTrie.Insert(change.Key, vs.serializeAccount(acc))
			}
		case ChangeTypePool:
			poolID := types.BytesToHash(change.Key)
			key := append([]byte("pool:"), poolID[:]...)
			if pool := vs.State.GetPool(types.PoolID(poolID)); pool != nil {
				vs.mptTrie.Insert(key, vs.serializePool(pool))
			}
		}
	}
}

// MPTRoot returns the current MPT root.
func (vs *VerifiableState) MPTRoot() types.Hash {
	return vs.mptTrie.Root()
}

// GenerateProof generates a Merkle proof for a key.
func (vs *VerifiableState) GenerateProof(key []byte) (*mpt.Proof, error) {
	return vs.mptTrie.Prove(key)
}

// Clone creates a deep copy.
func (vs *VerifiableState) Clone() *VerifiableState {
	return &VerifiableState{
		State:   vs.State.Clone(),
		mptTrie: vs.mptTrie.Clone(),
	}
}
