// Package dex implements DEX business logic.
package dex

import (
	"bytes"
	"math/big"

	"github.com/ethereum-optimism/optimism/demo/core/types"
)

const (
	// DefaultFeeRate is the default fee rate in basis points (30 = 0.3%)
	DefaultFeeRate = 30
	// FeeDenominator is the denominator for fee calculation
	FeeDenominator = 10000
)

// Pool represents an AMM liquidity pool.
type Pool struct {
	ID       types.PoolID
	TokenA   types.TokenID
	TokenB   types.TokenID
	ReserveA *big.Int // Token A reserve
	ReserveB *big.Int // Token B reserve
	TotalLP  *big.Int // Total LP token supply
	FeeRate  uint64   // Fee rate in basis points (e.g., 30 = 0.3%)
}

// NewPoolID creates a deterministic pool ID from two tokens.
// Tokens are sorted to ensure consistent ID regardless of order.
func NewPoolID(tokenA, tokenB types.TokenID) types.PoolID {
	// Ensure consistent ordering
	if bytes.Compare(tokenA[:], tokenB[:]) > 0 {
		tokenA, tokenB = tokenB, tokenA
	}
	data := append(tokenA[:], tokenB[:]...)
	return types.PoolID(types.Keccak256(data))
}

// NewPool creates a new pool.
func NewPool(tokenA, tokenB types.TokenID, feeRate uint64) *Pool {
	// Ensure consistent ordering
	if bytes.Compare(tokenA[:], tokenB[:]) > 0 {
		tokenA, tokenB = tokenB, tokenA
	}
	return &Pool{
		ID:       NewPoolID(tokenA, tokenB),
		TokenA:   tokenA,
		TokenB:   tokenB,
		ReserveA: big.NewInt(0),
		ReserveB: big.NewInt(0),
		TotalLP:  big.NewInt(0),
		FeeRate:  feeRate,
	}
}

// LPTokenID returns the LP token ID for this pool.
func (p *Pool) LPTokenID() types.TokenID {
	hash := types.Keccak256(p.ID[:])
	var id types.TokenID
	copy(id[:], hash[:20])
	return id
}

// GetTokenOrder returns tokens in the pool's canonical order.
// Also returns whether the input order was swapped.
func (p *Pool) GetTokenOrder(tokenIn types.TokenID) (reserveIn, reserveOut *big.Int, tokenOut types.TokenID, isTokenA bool) {
	if tokenIn == p.TokenA {
		return p.ReserveA, p.ReserveB, p.TokenB, true
	}
	return p.ReserveB, p.ReserveA, p.TokenA, false
}

// CalculateSwapOutput calculates the output amount for a swap.
// Uses the constant product formula: x * y = k
// amountOut = reserveOut * amountIn * (10000 - feeRate) / (reserveIn * 10000 + amountIn * (10000 - feeRate))
func (p *Pool) CalculateSwapOutput(amountIn *big.Int, reserveIn, reserveOut *big.Int) *big.Int {
	if amountIn == nil || amountIn.Sign() <= 0 {
		return big.NewInt(0)
	}
	if reserveIn == nil || reserveIn.Sign() <= 0 || reserveOut == nil || reserveOut.Sign() <= 0 {
		return big.NewInt(0)
	}

	// amountInWithFee = amountIn * (10000 - feeRate)
	feeMultiplier := big.NewInt(int64(FeeDenominator - p.FeeRate))
	amountInWithFee := new(big.Int).Mul(amountIn, feeMultiplier)

	// numerator = reserveOut * amountInWithFee
	numerator := new(big.Int).Mul(reserveOut, amountInWithFee)

	// denominator = reserveIn * 10000 + amountInWithFee
	denominator := new(big.Int).Mul(reserveIn, big.NewInt(FeeDenominator))
	denominator.Add(denominator, amountInWithFee)

	// amountOut = numerator / denominator
	return new(big.Int).Div(numerator, denominator)
}

// CalculateLPTokens calculates LP tokens to mint for adding liquidity.
// If pool is empty: LP = sqrt(amountA * amountB)
// If pool has liquidity: LP = min(amountA * totalLP / reserveA, amountB * totalLP / reserveB)
func (p *Pool) CalculateLPTokens(amountA, amountB *big.Int) *big.Int {
	if p.TotalLP.Sign() == 0 {
		// Initial liquidity: LP = sqrt(amountA * amountB)
		product := new(big.Int).Mul(amountA, amountB)
		return new(big.Int).Sqrt(product)
	}

	// LP tokens proportional to contribution
	lpFromA := new(big.Int).Mul(amountA, p.TotalLP)
	lpFromA.Div(lpFromA, p.ReserveA)

	lpFromB := new(big.Int).Mul(amountB, p.TotalLP)
	lpFromB.Div(lpFromB, p.ReserveB)

	// Return minimum to maintain ratio
	if lpFromA.Cmp(lpFromB) < 0 {
		return lpFromA
	}
	return lpFromB
}

// CalculateRemoveLiquidity calculates tokens to return when removing liquidity.
func (p *Pool) CalculateRemoveLiquidity(lpAmount *big.Int) (amountA, amountB *big.Int) {
	if p.TotalLP.Sign() == 0 || lpAmount.Sign() == 0 {
		return big.NewInt(0), big.NewInt(0)
	}

	// amountA = reserveA * lpAmount / totalLP
	amountA = new(big.Int).Mul(p.ReserveA, lpAmount)
	amountA.Div(amountA, p.TotalLP)

	// amountB = reserveB * lpAmount / totalLP
	amountB = new(big.Int).Mul(p.ReserveB, lpAmount)
	amountB.Div(amountB, p.TotalLP)

	return amountA, amountB
}

// Clone creates a deep copy of the pool.
func (p *Pool) Clone() *Pool {
	return &Pool{
		ID:       p.ID,
		TokenA:   p.TokenA,
		TokenB:   p.TokenB,
		ReserveA: new(big.Int).Set(p.ReserveA),
		ReserveB: new(big.Int).Set(p.ReserveB),
		TotalLP:  new(big.Int).Set(p.TotalLP),
		FeeRate:  p.FeeRate,
	}
}
