package main

import (
	"crypto/ecdsa"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// BatchProof mirrors the Solidity struct in TeeDisputeGame.sol:
//
//	struct BatchProof {
//	    bytes32 startBlockHash;
//	    bytes32 startStateHash;
//	    bytes32 endBlockHash;
//	    bytes32 endStateHash;
//	    uint256 l2Block;
//	    bytes   signature;
//	}
type BatchProof struct {
	StartBlockHash [32]byte
	StartStateHash [32]byte
	EndBlockHash   [32]byte
	EndStateHash   [32]byte
	L2Block        *big.Int
	Signature      []byte
}

// batchProofABIType is the ABI type for BatchProof[] used in abi.encode.
var batchProofABIType abi.Arguments

func init() {
	tupleType, err := abi.NewType("tuple[]", "", []abi.ArgumentMarshaling{
		{Name: "startBlockHash", Type: "bytes32"},
		{Name: "startStateHash", Type: "bytes32"},
		{Name: "endBlockHash", Type: "bytes32"},
		{Name: "endStateHash", Type: "bytes32"},
		{Name: "l2Block", Type: "uint256"},
		{Name: "signature", Type: "bytes"},
	})
	if err != nil {
		panic(fmt.Sprintf("failed to create BatchProof ABI type: %v", err))
	}
	batchProofABIType = abi.Arguments{{Type: tupleType}}
}

// digestABIArgs is used to compute keccak256(abi.encode(startBlockHash, startStateHash, endBlockHash, endStateHash, l2Block)).
var digestABIArgs abi.Arguments

func init() {
	bytes32Ty, _ := abi.NewType("bytes32", "", nil)
	uint256Ty, _ := abi.NewType("uint256", "", nil)
	digestABIArgs = abi.Arguments{
		{Type: bytes32Ty},
		{Type: bytes32Ty},
		{Type: bytes32Ty},
		{Type: bytes32Ty},
		{Type: uint256Ty},
	}
}

// computeBatchDigest computes keccak256(abi.encode(startBlockHash, startStateHash, endBlockHash, endStateHash, l2Block)).
func computeBatchDigest(startBlockHash, startStateHash, endBlockHash, endStateHash [32]byte, l2Block *big.Int) common.Hash {
	packed, err := digestABIArgs.Pack(startBlockHash, startStateHash, endBlockHash, endStateHash, l2Block)
	if err != nil {
		panic(fmt.Sprintf("failed to pack batch digest: %v", err))
	}
	return crypto.Keccak256Hash(packed)
}

// signBatchDigest signs a batch digest with the given ECDSA private key.
// Returns 65-byte signature [r(32) || s(32) || v(1)] with v = 27 or 28 (Solidity ecrecover convention).
func signBatchDigest(digest common.Hash, key *ecdsa.PrivateKey) ([]byte, error) {
	sig, err := crypto.Sign(digest.Bytes(), key)
	if err != nil {
		return nil, fmt.Errorf("failed to sign batch digest: %w", err)
	}
	// go-ethereum Sign returns v as 0/1; Solidity ecrecover expects 27/28
	sig[64] += 27
	return sig, nil
}

// generateProofBytes constructs an ABI-encoded BatchProof[] from a ProveRequest.
// It creates a single BatchProof covering the full range, signs it, and encodes.
func generateProofBytes(req ProveRequest, signerKey *ecdsa.PrivateKey) ([]byte, error) {
	startBlockHash := common.HexToHash(req.StartBlkHash)
	startStateHash := common.HexToHash(req.StartBlkStateHash)
	endBlockHash := common.HexToHash(req.EndBlkHash)
	endStateHash := common.HexToHash(req.EndBlkStateHash)
	l2Block := new(big.Int).SetUint64(req.EndBlkHeight)

	digest := computeBatchDigest(
		[32]byte(startBlockHash),
		[32]byte(startStateHash),
		[32]byte(endBlockHash),
		[32]byte(endStateHash),
		l2Block,
	)

	sig, err := signBatchDigest(digest, signerKey)
	if err != nil {
		return nil, err
	}

	// Build a single-element BatchProof array
	proofs := []struct {
		StartBlockHash [32]byte `abi:"startBlockHash"`
		StartStateHash [32]byte `abi:"startStateHash"`
		EndBlockHash   [32]byte `abi:"endBlockHash"`
		EndStateHash   [32]byte `abi:"endStateHash"`
		L2Block        *big.Int `abi:"l2Block"`
		Signature      []byte   `abi:"signature"`
	}{
		{
			StartBlockHash: [32]byte(startBlockHash),
			StartStateHash: [32]byte(startStateHash),
			EndBlockHash:   [32]byte(endBlockHash),
			EndStateHash:   [32]byte(endStateHash),
			L2Block:        l2Block,
			Signature:      sig,
		},
	}

	encoded, err := batchProofABIType.Pack(proofs)
	if err != nil {
		return nil, fmt.Errorf("failed to ABI-encode BatchProof[]: %w", err)
	}
	return encoded, nil
}
