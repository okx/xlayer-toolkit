// Package main implements the program for Cannon fault proofs.
// This program is compiled to MIPS and executed in the Cannon VM
// during dispute resolution.
package main

import (
	"encoding/binary"
	"os"

	"github.com/ethereum-optimism/optimism/demo/core/block"
	"github.com/ethereum-optimism/optimism/demo/core/mpt"
	"github.com/ethereum-optimism/optimism/demo/core/state"
	"github.com/ethereum-optimism/optimism/demo/core/tx"
	"github.com/ethereum-optimism/optimism/demo/core/types"
)

// File descriptors for Cannon VM preimage oracle
const (
	fdStdin         = 0
	fdStdout        = 1
	fdStderr        = 2
	fdHintRead      = 3
	fdHintWrite     = 4
	fdPreimageRead  = 5
	fdPreimageWrite = 6
)

// PreimageKeyType represents the type of preimage key
type PreimageKeyType byte

const (
	LocalKeyType    PreimageKeyType = 1
	Keccak256KeyType PreimageKeyType = 2
)

// PreimageOracle provides access to preimage data via the oracle.
// In Cannon VM, this communicates with the on-chain preimage oracle.
type PreimageOracle struct {
	// Current preimage key being read
	currentKey [32]byte
	// Offset into current preimage
	offset uint64
	// Cached preimage data (for local testing)
	preimages map[types.Hash][]byte
	// Whether to use syscalls (true in Cannon VM)
	useSyscalls bool
}

// NewPreimageOracle creates a new preimage oracle.
func NewPreimageOracle() *PreimageOracle {
	return &PreimageOracle{
		preimages:   make(map[types.Hash][]byte),
		useSyscalls: false, // Set to true when running in Cannon VM
	}
}

// SetKey sets the current preimage key to read.
func (o *PreimageOracle) SetKey(key [32]byte) {
	o.currentKey = key
	o.offset = 0

	if o.useSyscalls {
		// Write key to preimage oracle via syscall
		writePreimageKey(key[:])
	}
}

// Read reads data from the current preimage.
func (o *PreimageOracle) Read(dest []byte) int {
	if o.useSyscalls {
		// Read from preimage oracle via syscall
		n := readPreimage(dest)
		o.offset += uint64(n)
		return n
	}

	// Local testing: read from cached preimages
	key := types.BytesToHash(o.currentKey[:])
	data, ok := o.preimages[key]
	if !ok {
		return 0
	}

	// Add 8-byte length prefix
	prefixedData := make([]byte, 8+len(data))
	binary.BigEndian.PutUint64(prefixedData[:8], uint64(len(data)))
	copy(prefixedData[8:], data)

	// Read from offset
	if o.offset >= uint64(len(prefixedData)) {
		return 0
	}
	n := copy(dest, prefixedData[o.offset:])
	o.offset += uint64(n)
	return n
}

// Get retrieves a preimage by its hash.
func (o *PreimageOracle) Get(hash types.Hash) []byte {
	// Set the key
	var key [32]byte
	copy(key[:], hash[:])
	o.SetKey(key)

	// Read the length prefix first (8 bytes)
	var lenBuf [8]byte
	if o.Read(lenBuf[:]) < 8 {
		return nil
	}
	length := binary.BigEndian.Uint64(lenBuf[:])

	// Read the data
	data := make([]byte, length)
	totalRead := 0
	for totalRead < int(length) {
		n := o.Read(data[totalRead:])
		if n == 0 {
			break
		}
		totalRead += n
	}

	return data[:totalRead]
}

// Hint sends a hint to the oracle about needed data.
func (o *PreimageOracle) Hint(hint string) {
	if o.useSyscalls {
		writeHint([]byte(hint))
	}
}

// AddPreimage adds a preimage to the local cache (for testing).
func (o *PreimageOracle) AddPreimage(key types.Hash, data []byte) {
	o.preimages[key] = data
}

// writePreimageKey writes a preimage key to the oracle.
func writePreimageKey(key []byte) {
	// In Cannon VM, this writes to fdPreimageWrite
	// The syscall will be handled by the MIPS VM
	_, _ = os.NewFile(uintptr(fdPreimageWrite), "preimage-write").Write(key)
}

// readPreimage reads preimage data from the oracle.
func readPreimage(dest []byte) int {
	// In Cannon VM, this reads from fdPreimageRead
	n, _ := os.NewFile(uintptr(fdPreimageRead), "preimage-read").Read(dest)
	return n
}

// writeHint writes a hint to the oracle.
func writeHint(hint []byte) {
	// In Cannon VM, this writes to fdHintWrite
	_, _ = os.NewFile(uintptr(fdHintWrite), "hint-write").Write(hint)
}

// ProgramInputs holds the inputs for the fault proof program.
type ProgramInputs struct {
	BatchIndex     uint64
	PrevStateHash  types.Hash
	ClaimedMPTRoot types.Hash
	Blocks         []*block.Block
}

// Local data identifiers (matching Cannon convention)
const (
	LocalIdentL1Head      = 1
	LocalIdentOutputRoot  = 2
	LocalIdentClaimedRoot = 3
	LocalIdentL2BlockNum  = 4
	LocalIdentChainID     = 5
	// Custom identifiers for demo
	LocalIdentBatchIndex    = 10
	LocalIdentPrevStateHash = 11
	LocalIdentBlocksData    = 12
)

// ReadInputs reads program inputs from the preimage oracle.
func ReadInputs(oracle *PreimageOracle) *ProgramInputs {
	// Read batch index using local key
	batchIndexKey := makeLocalKey(LocalIdentBatchIndex)
	batchIndexBytes := oracle.Get(batchIndexKey)
	if len(batchIndexBytes) < 8 {
		batchIndexBytes = make([]byte, 8)
	}
	batchIndex := binary.BigEndian.Uint64(batchIndexBytes[:8])

	// Read previous state hash
	prevStateHashKey := makeLocalKey(LocalIdentPrevStateHash)
	prevStateHash := types.BytesToHash(oracle.Get(prevStateHashKey))

	// Read claimed MPT root
	claimedRootKey := makeLocalKey(LocalIdentClaimedRoot)
	claimedMPTRoot := types.BytesToHash(oracle.Get(claimedRootKey))

	// Read blocks data
	blocksKey := makeLocalKey(LocalIdentBlocksData)
	blocksData := oracle.Get(blocksKey)
	blocks := deserializeBlocks(blocksData)

	return &ProgramInputs{
		BatchIndex:     batchIndex,
		PrevStateHash:  prevStateHash,
		ClaimedMPTRoot: claimedMPTRoot,
		Blocks:         blocks,
	}
}

// makeLocalKey creates a local preimage key.
func makeLocalKey(ident uint64) types.Hash {
	var key types.Hash
	key[0] = byte(LocalKeyType)
	binary.BigEndian.PutUint64(key[24:], ident)
	return key
}

// deserializeBlocks deserializes blocks from bytes.
func deserializeBlocks(data []byte) []*block.Block {
	if len(data) == 0 {
		return nil
	}
	// Simplified - in practice would properly deserialize
	blk, err := block.DeserializeBlock(data)
	if err != nil {
		return nil
	}
	return []*block.Block{blk}
}

// ExecuteProgram executes the fault proof program.
// This is the main logic that runs in the Cannon VM.
func ExecuteProgram(oracle *PreimageOracle) int {
	// Send hint about what data we need
	oracle.Hint("l2-state-data")

	// Read inputs
	inputs := ReadInputs(oracle)

	// Initialize state with previous state hash
	s := state.NewState()
	s.SetStateHash(inputs.PrevStateHash)

	// Create verifiable state for MPT tracking
	vs := state.NewVerifiableStateFromState(s)

	// Create block builder for execution
	builder := block.NewBuilder()

	// Execute all blocks
	allChanges := make([]state.StateChange, 0)
	for _, blk := range inputs.Blocks {
		// Execute transactions
		for _, transaction := range blk.Transactions {
			result := executeTransaction(vs.State, transaction)
			if result != nil {
				allChanges = append(allChanges, result...)
			}
		}
	}

	// Update MPT with all changes
	vs.UpdateMPT(allChanges)

	// Compute incremental state hash
	vs.State.ComputeIncrementalHash(allChanges)

	// Compute MPT root
	computedMPTRoot := vs.MPTRoot()

	// Suppress unused variable warning
	_ = builder

	// Compare with claimed root
	if computedMPTRoot != inputs.ClaimedMPTRoot {
		// Claim is invalid - return 1 (challenger wins)
		return 1
	}

	// Claim is valid - return 0 (defender wins)
	return 0
}

// executeTransaction executes a single transaction.
func executeTransaction(s *state.State, transaction *tx.Transaction) []state.StateChange {
	executor := tx.NewExecutor()
	result := executor.Execute(s, transaction)
	if result.Success {
		changes := make([]state.StateChange, len(result.Changes))
		for i, c := range result.Changes {
			changes[i] = state.StateChange{
				Type: state.StateChangeType(c.Type),
				Key:  c.Key,
			}
		}
		return changes
	}
	return nil
}

// Unused function for linter
var _ = VerifyMerkleProof

// VerifyMerkleProof verifies a Merkle proof.
// This is used during step execution in the dispute game.
func VerifyMerkleProof(root types.Hash, key, value []byte, proof *mpt.Proof) bool {
	return mpt.VerifyProof(root, proof)
}

func main() {
	oracle := NewPreimageOracle()
	result := ExecuteProgram(oracle)
	os.Exit(result)
}
