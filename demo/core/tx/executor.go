// Package tx implements transaction execution.
package tx

import (
	"math/big"

	"github.com/ethereum-optimism/optimism/demo/core/dex"
	"github.com/ethereum-optimism/optimism/demo/core/state"
	"github.com/ethereum-optimism/optimism/demo/core/types"
)

// Executor executes transactions on state.
type Executor struct{}

// NewExecutor creates a new executor.
func NewExecutor() *Executor {
	return &Executor{}
}

// ExecuteResult represents the result of executing a transaction.
type ExecuteResult struct {
	Success bool
	Error   error
	Changes []state.StateChange
}

// Execute executes a transaction on the given state.
func (e *Executor) Execute(s *state.State, tx *Transaction) *ExecuteResult {
	result := &ExecuteResult{
		Success: false,
		Changes: make([]state.StateChange, 0),
	}

	// Verify signature
	if !tx.VerifySignature() {
		result.Error = types.ErrInvalidSignature
		return result
	}

	// Get sender account
	sender := s.GetAccount(tx.From)
	if sender == nil {
		// Create account if it doesn't exist
		sender = s.GetOrCreateAccount(tx.From)
	}

	// Verify nonce
	if sender.Nonce != tx.Nonce {
		result.Error = types.ErrInvalidNonce
		return result
	}

	// Deduct fee
	if tx.Fee.Amount != nil && tx.Fee.Amount.Sign() > 0 {
		if err := sender.SubBalance(tx.Fee.Token, tx.Fee.Amount); err != nil {
			result.Error = types.ErrInsufficientFee
			return result
		}
	}

	// Execute based on transaction type
	var err error
	switch tx.Type {
	case types.TxTypeTransfer:
		err = e.executeTransfer(s, sender, tx.Payload, &result.Changes)
	case types.TxTypeSwap:
		err = e.executeSwap(s, sender, tx.Payload, &result.Changes)
	case types.TxTypeAddLiquidity:
		err = e.executeAddLiquidity(s, sender, tx.Payload, &result.Changes)
	case types.TxTypeRemoveLiquidity:
		err = e.executeRemoveLiquidity(s, sender, tx.Payload, &result.Changes)
	case types.TxTypeCreatePool:
		err = e.executeCreatePool(s, sender, tx.Payload, &result.Changes)
	default:
		err = types.ErrUnknownTxType
	}

	if err != nil {
		result.Error = err
		return result
	}

	// Increment nonce
	sender.Nonce++

	result.Success = true
	return result
}

// executeTransfer executes a transfer transaction.
func (e *Executor) executeTransfer(s *state.State, sender *dex.Account, payload []byte, changes *[]state.StateChange) error {
	p, err := DecodeTransferPayload(payload)
	if err != nil {
		return types.ErrInvalidPayload
	}

	if p.Amount == nil || p.Amount.Sign() <= 0 {
		return types.ErrZeroAmount
	}

	// Deduct from sender
	if err := sender.SubBalance(p.Token, p.Amount); err != nil {
		return err
	}

	// Add to receiver
	receiver := s.GetOrCreateAccount(p.To)
	receiver.AddBalance(p.Token, p.Amount)

	// Record changes
	*changes = append(*changes, state.StateChange{
		Type: state.ChangeTypeAccount,
		Key:  sender.Address[:],
	})
	*changes = append(*changes, state.StateChange{
		Type: state.ChangeTypeAccount,
		Key:  receiver.Address[:],
	})

	return nil
}

// executeSwap executes a swap transaction.
func (e *Executor) executeSwap(s *state.State, sender *dex.Account, payload []byte, changes *[]state.StateChange) error {
	p, err := DecodeSwapPayload(payload)
	if err != nil {
		return types.ErrInvalidPayload
	}

	if p.AmountIn == nil || p.AmountIn.Sign() <= 0 {
		return types.ErrZeroAmount
	}

	// Get pool
	pool := s.GetPool(p.PoolID)
	if pool == nil {
		return types.ErrPoolNotFound
	}

	// Determine token order
	reserveIn, reserveOut, tokenOut, isTokenA := pool.GetTokenOrder(p.TokenIn)
	if reserveIn == nil {
		return types.ErrInvalidToken
	}

	// Calculate output
	amountOut := pool.CalculateSwapOutput(p.AmountIn, reserveIn, reserveOut)

	// Slippage check
	if p.MinAmountOut != nil && amountOut.Cmp(p.MinAmountOut) < 0 {
		return types.ErrSlippageExceeded
	}

	// Deduct input from sender
	if err := sender.SubBalance(p.TokenIn, p.AmountIn); err != nil {
		return err
	}

	// Update pool reserves
	if isTokenA {
		pool.ReserveA = new(big.Int).Add(pool.ReserveA, p.AmountIn)
		pool.ReserveB = new(big.Int).Sub(pool.ReserveB, amountOut)
	} else {
		pool.ReserveB = new(big.Int).Add(pool.ReserveB, p.AmountIn)
		pool.ReserveA = new(big.Int).Sub(pool.ReserveA, amountOut)
	}

	// Add output to sender
	sender.AddBalance(tokenOut, amountOut)

	// Record changes
	*changes = append(*changes, state.StateChange{
		Type: state.ChangeTypeAccount,
		Key:  sender.Address[:],
	})
	*changes = append(*changes, state.StateChange{
		Type: state.ChangeTypePool,
		Key:  pool.ID[:],
	})

	return nil
}

// executeAddLiquidity executes an add liquidity transaction.
func (e *Executor) executeAddLiquidity(s *state.State, sender *dex.Account, payload []byte, changes *[]state.StateChange) error {
	p, err := DecodeAddLiquidityPayload(payload)
	if err != nil {
		return types.ErrInvalidPayload
	}

	// Get pool
	pool := s.GetPool(p.PoolID)
	if pool == nil {
		return types.ErrPoolNotFound
	}

	// Calculate actual amounts to add (maintain ratio)
	var actualA, actualB *big.Int
	if pool.TotalLP.Sign() == 0 {
		// First liquidity, use provided amounts
		actualA = p.AmountA
		actualB = p.AmountB
	} else {
		// Calculate proportional amounts
		ratioA := new(big.Int).Mul(p.AmountA, pool.ReserveB)
		ratioB := new(big.Int).Mul(p.AmountB, pool.ReserveA)

		if ratioA.Cmp(ratioB) <= 0 {
			actualA = p.AmountA
			actualB = new(big.Int).Mul(p.AmountA, pool.ReserveB)
			actualB.Div(actualB, pool.ReserveA)
		} else {
			actualB = p.AmountB
			actualA = new(big.Int).Mul(p.AmountB, pool.ReserveA)
			actualA.Div(actualA, pool.ReserveB)
		}
	}

	// Calculate LP tokens
	lpAmount := pool.CalculateLPTokens(actualA, actualB)

	// Slippage check
	if p.MinLP != nil && lpAmount.Cmp(p.MinLP) < 0 {
		return types.ErrSlippageExceeded
	}

	// Deduct tokens from sender
	if err := sender.SubBalance(pool.TokenA, actualA); err != nil {
		return err
	}
	if err := sender.SubBalance(pool.TokenB, actualB); err != nil {
		// Rollback first deduction
		sender.AddBalance(pool.TokenA, actualA)
		return err
	}

	// Update pool
	pool.ReserveA = new(big.Int).Add(pool.ReserveA, actualA)
	pool.ReserveB = new(big.Int).Add(pool.ReserveB, actualB)
	pool.TotalLP = new(big.Int).Add(pool.TotalLP, lpAmount)

	// Mint LP tokens to sender
	sender.AddBalance(pool.LPTokenID(), lpAmount)

	// Record changes
	*changes = append(*changes, state.StateChange{
		Type: state.ChangeTypeAccount,
		Key:  sender.Address[:],
	})
	*changes = append(*changes, state.StateChange{
		Type: state.ChangeTypePool,
		Key:  pool.ID[:],
	})

	return nil
}

// executeRemoveLiquidity executes a remove liquidity transaction.
func (e *Executor) executeRemoveLiquidity(s *state.State, sender *dex.Account, payload []byte, changes *[]state.StateChange) error {
	p, err := DecodeRemoveLiquidityPayload(payload)
	if err != nil {
		return types.ErrInvalidPayload
	}

	// Get pool
	pool := s.GetPool(p.PoolID)
	if pool == nil {
		return types.ErrPoolNotFound
	}

	// Calculate tokens to return
	amountA, amountB := pool.CalculateRemoveLiquidity(p.LPAmount)

	// Slippage check
	if (p.MinA != nil && amountA.Cmp(p.MinA) < 0) || (p.MinB != nil && amountB.Cmp(p.MinB) < 0) {
		return types.ErrSlippageExceeded
	}

	// Burn LP tokens from sender
	if err := sender.SubBalance(pool.LPTokenID(), p.LPAmount); err != nil {
		return err
	}

	// Update pool
	pool.ReserveA = new(big.Int).Sub(pool.ReserveA, amountA)
	pool.ReserveB = new(big.Int).Sub(pool.ReserveB, amountB)
	pool.TotalLP = new(big.Int).Sub(pool.TotalLP, p.LPAmount)

	// Return tokens to sender
	sender.AddBalance(pool.TokenA, amountA)
	sender.AddBalance(pool.TokenB, amountB)

	// Record changes
	*changes = append(*changes, state.StateChange{
		Type: state.ChangeTypeAccount,
		Key:  sender.Address[:],
	})
	*changes = append(*changes, state.StateChange{
		Type: state.ChangeTypePool,
		Key:  pool.ID[:],
	})

	return nil
}

// executeCreatePool executes a create pool transaction.
func (e *Executor) executeCreatePool(s *state.State, sender *dex.Account, payload []byte, changes *[]state.StateChange) error {
	p, err := DecodeCreatePoolPayload(payload)
	if err != nil {
		return types.ErrInvalidPayload
	}

	if p.AmountA == nil || p.AmountA.Sign() <= 0 || p.AmountB == nil || p.AmountB.Sign() <= 0 {
		return types.ErrZeroAmount
	}

	// Check if pool already exists
	poolID := dex.NewPoolID(p.TokenA, p.TokenB)
	if s.GetPool(poolID) != nil {
		return types.ErrPoolExists
	}

	// Set default fee rate if not provided
	feeRate := p.FeeRate
	if feeRate == 0 {
		feeRate = dex.DefaultFeeRate
	}

	// Deduct tokens from sender
	if err := sender.SubBalance(p.TokenA, p.AmountA); err != nil {
		return err
	}
	if err := sender.SubBalance(p.TokenB, p.AmountB); err != nil {
		// Rollback
		sender.AddBalance(p.TokenA, p.AmountA)
		return err
	}

	// Create pool
	pool := dex.NewPool(p.TokenA, p.TokenB, feeRate)
	pool.ReserveA = new(big.Int).Set(p.AmountA)
	pool.ReserveB = new(big.Int).Set(p.AmountB)

	// Calculate initial LP tokens: sqrt(amountA * amountB)
	product := new(big.Int).Mul(p.AmountA, p.AmountB)
	initialLP := new(big.Int).Sqrt(product)
	pool.TotalLP = initialLP

	// Add pool to state
	s.SetPool(pool)

	// Mint LP tokens to sender
	sender.AddBalance(pool.LPTokenID(), initialLP)

	// Record changes
	*changes = append(*changes, state.StateChange{
		Type: state.ChangeTypeAccount,
		Key:  sender.Address[:],
	})
	*changes = append(*changes, state.StateChange{
		Type: state.ChangeTypePool,
		Key:  pool.ID[:],
	})

	return nil
}
