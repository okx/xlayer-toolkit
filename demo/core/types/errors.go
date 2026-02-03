// Package types defines common errors used across demo.
package types

import "errors"

// Common errors.
var (
	// Account errors
	ErrAccountNotFound     = errors.New("account not found")
	ErrInsufficientBalance = errors.New("insufficient balance")
	ErrInvalidNonce        = errors.New("invalid nonce")
	ErrInsufficientFee     = errors.New("insufficient fee")

	// Transaction errors
	ErrInvalidSignature = errors.New("invalid signature")
	ErrUnknownTxType    = errors.New("unknown transaction type")
	ErrInvalidPayload   = errors.New("invalid payload")

	// Pool errors
	ErrPoolExists       = errors.New("pool already exists")
	ErrPoolNotFound     = errors.New("pool not found")
	ErrInvalidToken     = errors.New("invalid token")
	ErrZeroAmount       = errors.New("zero amount")
	ErrSlippageExceeded = errors.New("slippage exceeded")

	// State errors
	ErrInvalidStateHash = errors.New("invalid state hash")
	ErrInvalidMPTRoot   = errors.New("invalid MPT root")

	// Block errors
	ErrInvalidBlock       = errors.New("invalid block")
	ErrInvalidParentHash  = errors.New("invalid parent hash")
	ErrInvalidBlockNumber = errors.New("invalid block number")
)
