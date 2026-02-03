// Package types defines common types used across core, node, and program.
package types

import (
	"crypto/sha256"
	"encoding/binary"
	"math/big"
)

// Address represents a 20-byte account address.
type Address [20]byte

// Hash represents a 32-byte hash.
type Hash [32]byte

// TokenID represents a 20-byte token identifier.
type TokenID [20]byte

// PoolID represents a 32-byte pool identifier.
type PoolID [32]byte

// Signature represents a cryptographic signature.
type Signature struct {
	R [32]byte
	S [32]byte
	V byte
}

// Fee represents transaction fee.
type Fee struct {
	Token  TokenID
	Amount *big.Int
}

// TxType represents the type of transaction.
type TxType uint8

const (
	TxTypeTransfer        TxType = 1 // Transfer tokens between accounts
	TxTypeSwap            TxType = 2 // AMM swap
	TxTypeAddLiquidity    TxType = 3 // Add liquidity to pool
	TxTypeRemoveLiquidity TxType = 4 // Remove liquidity from pool
	TxTypeCreatePool      TxType = 5 // Create new trading pair
)

// Predefined tokens.
var (
	TokenETH  = TokenID{0x00} // Native token
	TokenUSDC = TokenID{0x01} // Stablecoin
	TokenBTC  = TokenID{0x02} // Wrapped BTC
)

// ZeroAddress is the zero address.
var ZeroAddress = Address{}

// ZeroHash is the zero hash.
var ZeroHash = Hash{}

// BytesToAddress converts bytes to Address.
func BytesToAddress(b []byte) Address {
	var addr Address
	if len(b) > 20 {
		b = b[len(b)-20:]
	}
	copy(addr[20-len(b):], b)
	return addr
}

// BytesToHash converts bytes to Hash.
func BytesToHash(b []byte) Hash {
	var h Hash
	if len(b) > 32 {
		b = b[len(b)-32:]
	}
	copy(h[32-len(b):], b)
	return h
}

// Bytes returns the byte slice of Address.
func (a Address) Bytes() []byte {
	return a[:]
}

// Bytes returns the byte slice of Hash.
func (h Hash) Bytes() []byte {
	return h[:]
}

// Bytes returns the byte slice of TokenID.
func (t TokenID) Bytes() []byte {
	return t[:]
}

// Bytes returns the byte slice of PoolID.
func (p PoolID) Bytes() []byte {
	return p[:]
}

// Keccak256 computes SHA256 hash (using SHA256 for simplicity in MVP).
func Keccak256(data ...[]byte) Hash {
	h := sha256.New()
	for _, d := range data {
		h.Write(d)
	}
	var result Hash
	copy(result[:], h.Sum(nil))
	return result
}

// Uint64ToBytes converts uint64 to bytes.
func Uint64ToBytes(n uint64) []byte {
	b := make([]byte, 8)
	binary.BigEndian.PutUint64(b, n)
	return b
}

// BytesToUint64 converts bytes to uint64.
func BytesToUint64(b []byte) uint64 {
	if len(b) < 8 {
		padded := make([]byte, 8)
		copy(padded[8-len(b):], b)
		b = padded
	}
	return binary.BigEndian.Uint64(b)
}

// BigIntToBytes converts big.Int to bytes.
func BigIntToBytes(n *big.Int) []byte {
	if n == nil {
		return []byte{0}
	}
	return n.Bytes()
}

// BytesToBigInt converts bytes to big.Int.
func BytesToBigInt(b []byte) *big.Int {
	return new(big.Int).SetBytes(b)
}
