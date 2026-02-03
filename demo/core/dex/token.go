// Package dex implements DEX business logic.
package dex

import (
	"math/big"

	"github.com/ethereum-optimism/optimism/demo/core/types"
)

// Token represents a token definition.
type Token struct {
	ID          types.TokenID
	Name        string
	Symbol      string
	Decimals    uint8
	TotalSupply *big.Int
}

// NewToken creates a new token.
func NewToken(id types.TokenID, name, symbol string, decimals uint8) *Token {
	return &Token{
		ID:          id,
		Name:        name,
		Symbol:      symbol,
		Decimals:    decimals,
		TotalSupply: big.NewInt(0),
	}
}

// Clone creates a deep copy of the token.
func (t *Token) Clone() *Token {
	return &Token{
		ID:          t.ID,
		Name:        t.Name,
		Symbol:      t.Symbol,
		Decimals:    t.Decimals,
		TotalSupply: new(big.Int).Set(t.TotalSupply),
	}
}

// DefaultTokens returns the default predefined tokens.
func DefaultTokens() map[types.TokenID]*Token {
	return map[types.TokenID]*Token{
		types.TokenETH: {
			ID:          types.TokenETH,
			Name:        "Ether",
			Symbol:      "ETH",
			Decimals:    18,
			TotalSupply: big.NewInt(0),
		},
		types.TokenUSDC: {
			ID:          types.TokenUSDC,
			Name:        "USD Coin",
			Symbol:      "USDC",
			Decimals:    6,
			TotalSupply: big.NewInt(0),
		},
		types.TokenBTC: {
			ID:          types.TokenBTC,
			Name:        "Wrapped Bitcoin",
			Symbol:      "WBTC",
			Decimals:    8,
			TotalSupply: big.NewInt(0),
		},
	}
}
