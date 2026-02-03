// Package tx implements transaction definitions and execution.
package tx

import (
	"bytes"
	"encoding/gob"
	"math/big"

	"github.com/ethereum-optimism/optimism/demo/core/types"
)

// Transaction represents a transaction in demo.
type Transaction struct {
	Type      types.TxType
	From      types.Address
	Payload   []byte
	Fee       types.Fee
	Nonce     uint64
	Signature types.Signature
}

// Hash returns the hash of the transaction.
func (tx *Transaction) Hash() types.Hash {
	data := tx.SigningData()
	return types.Keccak256(data)
}

// SigningData returns the data to be signed.
func (tx *Transaction) SigningData() []byte {
	var buf bytes.Buffer
	buf.WriteByte(byte(tx.Type))
	buf.Write(tx.From[:])
	buf.Write(tx.Payload)
	buf.Write(tx.Fee.Token[:])
	buf.Write(types.BigIntToBytes(tx.Fee.Amount))
	buf.Write(types.Uint64ToBytes(tx.Nonce))
	return buf.Bytes()
}

// VerifySignature verifies the transaction signature.
// TODO: Implement actual signature verification.
func (tx *Transaction) VerifySignature() bool {
	// For MVP, we skip signature verification
	// In production, this should verify ECDSA signature
	return true
}

// TransferPayload represents a transfer transaction payload.
type TransferPayload struct {
	To     types.Address
	Token  types.TokenID
	Amount *big.Int
}

// Encode encodes the payload to bytes.
func (p *TransferPayload) Encode() ([]byte, error) {
	var buf bytes.Buffer
	enc := gob.NewEncoder(&buf)
	if err := enc.Encode(p); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// DecodeTransferPayload decodes bytes to TransferPayload.
func DecodeTransferPayload(data []byte) (*TransferPayload, error) {
	var p TransferPayload
	dec := gob.NewDecoder(bytes.NewReader(data))
	if err := dec.Decode(&p); err != nil {
		return nil, err
	}
	return &p, nil
}

// SwapPayload represents a swap transaction payload.
type SwapPayload struct {
	PoolID       types.PoolID
	TokenIn      types.TokenID
	AmountIn     *big.Int
	MinAmountOut *big.Int // Slippage protection
}

// Encode encodes the payload to bytes.
func (p *SwapPayload) Encode() ([]byte, error) {
	var buf bytes.Buffer
	enc := gob.NewEncoder(&buf)
	if err := enc.Encode(p); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// DecodeSwapPayload decodes bytes to SwapPayload.
func DecodeSwapPayload(data []byte) (*SwapPayload, error) {
	var p SwapPayload
	dec := gob.NewDecoder(bytes.NewReader(data))
	if err := dec.Decode(&p); err != nil {
		return nil, err
	}
	return &p, nil
}

// AddLiquidityPayload represents an add liquidity transaction payload.
type AddLiquidityPayload struct {
	PoolID  types.PoolID
	AmountA *big.Int
	AmountB *big.Int
	MinLP   *big.Int // Minimum LP tokens to receive
}

// Encode encodes the payload to bytes.
func (p *AddLiquidityPayload) Encode() ([]byte, error) {
	var buf bytes.Buffer
	enc := gob.NewEncoder(&buf)
	if err := enc.Encode(p); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// DecodeAddLiquidityPayload decodes bytes to AddLiquidityPayload.
func DecodeAddLiquidityPayload(data []byte) (*AddLiquidityPayload, error) {
	var p AddLiquidityPayload
	dec := gob.NewDecoder(bytes.NewReader(data))
	if err := dec.Decode(&p); err != nil {
		return nil, err
	}
	return &p, nil
}

// RemoveLiquidityPayload represents a remove liquidity transaction payload.
type RemoveLiquidityPayload struct {
	PoolID   types.PoolID
	LPAmount *big.Int
	MinA     *big.Int // Minimum token A to receive
	MinB     *big.Int // Minimum token B to receive
}

// Encode encodes the payload to bytes.
func (p *RemoveLiquidityPayload) Encode() ([]byte, error) {
	var buf bytes.Buffer
	enc := gob.NewEncoder(&buf)
	if err := enc.Encode(p); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// DecodeRemoveLiquidityPayload decodes bytes to RemoveLiquidityPayload.
func DecodeRemoveLiquidityPayload(data []byte) (*RemoveLiquidityPayload, error) {
	var p RemoveLiquidityPayload
	dec := gob.NewDecoder(bytes.NewReader(data))
	if err := dec.Decode(&p); err != nil {
		return nil, err
	}
	return &p, nil
}

// CreatePoolPayload represents a create pool transaction payload.
type CreatePoolPayload struct {
	TokenA  types.TokenID
	TokenB  types.TokenID
	AmountA *big.Int
	AmountB *big.Int
	FeeRate uint64 // Fee rate in basis points (default: 30 = 0.3%)
}

// Encode encodes the payload to bytes.
func (p *CreatePoolPayload) Encode() ([]byte, error) {
	var buf bytes.Buffer
	enc := gob.NewEncoder(&buf)
	if err := enc.Encode(p); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// DecodeCreatePoolPayload decodes bytes to CreatePoolPayload.
func DecodeCreatePoolPayload(data []byte) (*CreatePoolPayload, error) {
	var p CreatePoolPayload
	dec := gob.NewDecoder(bytes.NewReader(data))
	if err := dec.Decode(&p); err != nil {
		return nil, err
	}
	return &p, nil
}
