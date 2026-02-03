// Package dex implements DEX business logic.
package dex

import (
	"math/big"

	"github.com/ethereum-optimism/optimism/demo/core/types"
)

// Account represents a user account with multi-token balances.
type Account struct {
	Address  types.Address
	Nonce    uint64
	Balances map[types.TokenID]*big.Int
}

// NewAccount creates a new account.
func NewAccount(addr types.Address) *Account {
	return &Account{
		Address:  addr,
		Nonce:    0,
		Balances: make(map[types.TokenID]*big.Int),
	}
}

// GetBalance returns the balance of a specific token.
func (a *Account) GetBalance(token types.TokenID) *big.Int {
	if bal, ok := a.Balances[token]; ok {
		return new(big.Int).Set(bal)
	}
	return big.NewInt(0)
}

// SetBalance sets the balance of a specific token.
func (a *Account) SetBalance(token types.TokenID, amount *big.Int) {
	if amount == nil {
		amount = big.NewInt(0)
	}
	a.Balances[token] = new(big.Int).Set(amount)
}

// AddBalance adds amount to the balance of a specific token.
func (a *Account) AddBalance(token types.TokenID, amount *big.Int) {
	if amount == nil || amount.Sign() == 0 {
		return
	}
	bal := a.GetBalance(token)
	a.Balances[token] = new(big.Int).Add(bal, amount)
}

// SubBalance subtracts amount from the balance of a specific token.
// Returns error if insufficient balance.
func (a *Account) SubBalance(token types.TokenID, amount *big.Int) error {
	if amount == nil || amount.Sign() == 0 {
		return nil
	}
	bal := a.GetBalance(token)
	if bal.Cmp(amount) < 0 {
		return types.ErrInsufficientBalance
	}
	a.Balances[token] = new(big.Int).Sub(bal, amount)
	return nil
}

// IncrementNonce increments the account nonce.
func (a *Account) IncrementNonce() {
	a.Nonce++
}

// Clone creates a deep copy of the account.
func (a *Account) Clone() *Account {
	clone := &Account{
		Address:  a.Address,
		Nonce:    a.Nonce,
		Balances: make(map[types.TokenID]*big.Int),
	}
	for token, bal := range a.Balances {
		clone.Balances[token] = new(big.Int).Set(bal)
	}
	return clone
}
