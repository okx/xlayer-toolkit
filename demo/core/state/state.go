// Package state implements state management for demo.
package state

import (
	"bytes"
	"encoding/gob"
	"sort"

	"github.com/ethereum-optimism/optimism/demo/core/dex"
	"github.com/ethereum-optimism/optimism/demo/core/types"
)

// State represents the entire state of the demo DEX.
type State struct {
	Accounts map[types.Address]*dex.Account
	Tokens   map[types.TokenID]*dex.Token
	Pools    map[types.PoolID]*dex.Pool

	// State hash tracking
	stateHash types.Hash // Current incremental state hash
}

// NewState creates a new empty state.
func NewState() *State {
	// Genesis state hash is derived from "demo-genesis"
	genesisHash := types.Keccak256([]byte("demo-genesis-state-v1"))
	return &State{
		Accounts:  make(map[types.Address]*dex.Account),
		Tokens:    dex.DefaultTokens(),
		Pools:     make(map[types.PoolID]*dex.Pool),
		stateHash: genesisHash,
	}
}

// GetAccount returns the account for the given address.
// Creates a new account if it doesn't exist.
func (s *State) GetAccount(addr types.Address) *dex.Account {
	if acc, ok := s.Accounts[addr]; ok {
		return acc
	}
	return nil
}

// GetOrCreateAccount returns the account for the given address.
// Creates a new account if it doesn't exist.
func (s *State) GetOrCreateAccount(addr types.Address) *dex.Account {
	if acc, ok := s.Accounts[addr]; ok {
		return acc
	}
	acc := dex.NewAccount(addr)
	s.Accounts[addr] = acc
	return acc
}

// SetAccount sets the account for the given address.
func (s *State) SetAccount(acc *dex.Account) {
	s.Accounts[acc.Address] = acc
}

// GetToken returns the token for the given ID.
func (s *State) GetToken(id types.TokenID) *dex.Token {
	return s.Tokens[id]
}

// SetToken sets the token for the given ID.
func (s *State) SetToken(token *dex.Token) {
	s.Tokens[token.ID] = token
}

// GetPool returns the pool for the given ID.
func (s *State) GetPool(id types.PoolID) *dex.Pool {
	return s.Pools[id]
}

// GetPoolByTokens returns the pool for the given token pair.
func (s *State) GetPoolByTokens(tokenA, tokenB types.TokenID) *dex.Pool {
	poolID := dex.NewPoolID(tokenA, tokenB)
	return s.Pools[poolID]
}

// SetPool sets the pool for the given ID.
func (s *State) SetPool(pool *dex.Pool) {
	s.Pools[pool.ID] = pool
}

// StateHash returns the current state hash.
func (s *State) StateHash() types.Hash {
	return s.stateHash
}

// SetStateHash sets the state hash (used for initialization).
func (s *State) SetStateHash(hash types.Hash) {
	s.stateHash = hash
}

// StateChange represents a single state change.
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

// ComputeIncrementalHash computes the new state hash based on changes.
// StateHash_new = SHA256(StateHash_old || serialize(changes))
func (s *State) ComputeIncrementalHash(changes []StateChange) types.Hash {
	if len(changes) == 0 {
		return s.stateHash
	}

	// Serialize changes
	changesData := serializeChanges(changes)

	// Compute new hash: SHA256(prevHash || changesData)
	newHash := types.Keccak256(s.stateHash[:], changesData)
	s.stateHash = newHash

	return newHash
}

// serializeChanges serializes state changes to bytes.
func serializeChanges(changes []StateChange) []byte {
	// Sort changes for determinism
	sort.Slice(changes, func(i, j int) bool {
		if changes[i].Type != changes[j].Type {
			return changes[i].Type < changes[j].Type
		}
		return bytes.Compare(changes[i].Key, changes[j].Key) < 0
	})

	var buf bytes.Buffer
	enc := gob.NewEncoder(&buf)
	_ = enc.Encode(changes)
	return buf.Bytes()
}

// Clone creates a deep copy of the state.
func (s *State) Clone() *State {
	clone := &State{
		Accounts:  make(map[types.Address]*dex.Account),
		Tokens:    make(map[types.TokenID]*dex.Token),
		Pools:     make(map[types.PoolID]*dex.Pool),
		stateHash: s.stateHash,
	}

	for addr, acc := range s.Accounts {
		clone.Accounts[addr] = acc.Clone()
	}
	for id, token := range s.Tokens {
		clone.Tokens[id] = token.Clone()
	}
	for id, pool := range s.Pools {
		clone.Pools[id] = pool.Clone()
	}

	return clone
}

// Serialize serializes the state to bytes.
func (s *State) Serialize() ([]byte, error) {
	var buf bytes.Buffer
	enc := gob.NewEncoder(&buf)
	if err := enc.Encode(s); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// Deserialize deserializes the state from bytes.
func Deserialize(data []byte) (*State, error) {
	var s State
	dec := gob.NewDecoder(bytes.NewReader(data))
	if err := dec.Decode(&s); err != nil {
		return nil, err
	}
	return &s, nil
}
