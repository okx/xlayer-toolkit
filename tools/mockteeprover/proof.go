package main

import (
	"crypto/ecdsa"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// EIP-712 constants matching TeeDisputeGame.sol
var (
	// keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
	domainTypehash = crypto.Keccak256Hash([]byte("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"))
	// keccak256("TeeDisputeGame")
	domainNameHash = crypto.Keccak256Hash([]byte("TeeDisputeGame"))
	// keccak256("1")
	domainVersionHash = crypto.Keccak256Hash([]byte("1"))
	// keccak256("BatchProof(bytes32 startBlockHash,bytes32 startStateHash,bytes32 endBlockHash,bytes32 endStateHash,uint256 l2Block)")
	batchProofTypehash = crypto.Keccak256Hash([]byte("BatchProof(bytes32 startBlockHash,bytes32 startStateHash,bytes32 endBlockHash,bytes32 endStateHash,uint256 l2Block)"))
)

// EIP712DomainConfig holds the chain-specific EIP-712 domain parameters.
type EIP712DomainConfig struct {
	ChainID            *big.Int
	VerifyingContract  common.Address
}

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

// structHashABIArgs is used to compute keccak256(abi.encode(BATCH_PROOF_TYPEHASH, ...fields...)).
var structHashABIArgs abi.Arguments

func init() {
	bytes32Ty, _ := abi.NewType("bytes32", "", nil)
	uint256Ty, _ := abi.NewType("uint256", "", nil)
	structHashABIArgs = abi.Arguments{
		{Type: bytes32Ty}, // BATCH_PROOF_TYPEHASH
		{Type: bytes32Ty}, // startBlockHash
		{Type: bytes32Ty}, // startStateHash
		{Type: bytes32Ty}, // endBlockHash
		{Type: bytes32Ty}, // endStateHash
		{Type: uint256Ty}, // l2Block
	}
}

// domainSeparatorABIArgs is used to compute the EIP-712 domain separator.
var domainSeparatorABIArgs abi.Arguments

func init() {
	bytes32Ty, _ := abi.NewType("bytes32", "", nil)
	uint256Ty, _ := abi.NewType("uint256", "", nil)
	addressTy, _ := abi.NewType("address", "", nil)
	domainSeparatorABIArgs = abi.Arguments{
		{Type: bytes32Ty}, // DOMAIN_TYPEHASH
		{Type: bytes32Ty}, // nameHash
		{Type: bytes32Ty}, // versionHash
		{Type: uint256Ty}, // chainId
		{Type: addressTy}, // verifyingContract
	}
}

// computeDomainSeparator computes the EIP-712 domain separator matching TeeDisputeGame._domainSeparator().
func computeDomainSeparator(cfg EIP712DomainConfig) common.Hash {
	packed, err := domainSeparatorABIArgs.Pack(
		[32]byte(domainTypehash),
		[32]byte(domainNameHash),
		[32]byte(domainVersionHash),
		cfg.ChainID,
		cfg.VerifyingContract,
	)
	if err != nil {
		panic(fmt.Sprintf("failed to pack domain separator: %v", err))
	}
	return crypto.Keccak256Hash(packed)
}

// computeEIP712Digest computes the full EIP-712 digest:
// keccak256("\x19\x01" || domainSeparator || structHash)
// where structHash = keccak256(abi.encode(BATCH_PROOF_TYPEHASH, startBlockHash, startStateHash, endBlockHash, endStateHash, l2Block))
func computeEIP712Digest(domainSep common.Hash, startBlockHash, startStateHash, endBlockHash, endStateHash [32]byte, l2Block *big.Int) common.Hash {
	// structHash = keccak256(abi.encode(BATCH_PROOF_TYPEHASH, ...))
	packed, err := structHashABIArgs.Pack(
		[32]byte(batchProofTypehash),
		startBlockHash,
		startStateHash,
		endBlockHash,
		endStateHash,
		l2Block,
	)
	if err != nil {
		panic(fmt.Sprintf("failed to pack struct hash: %v", err))
	}
	structHash := crypto.Keccak256Hash(packed)

	// EIP-712: keccak256("\x19\x01" || domainSeparator || structHash)
	raw := make([]byte, 2+32+32)
	raw[0] = 0x19
	raw[1] = 0x01
	copy(raw[2:34], domainSep.Bytes())
	copy(raw[34:66], structHash.Bytes())
	return crypto.Keccak256Hash(raw)
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
// It creates a single BatchProof covering the full range, signs it with EIP-712, and encodes.
func generateProofBytes(req ProveRequest, signerKey *ecdsa.PrivateKey, domainSep common.Hash) ([]byte, error) {
	startBlockHash := common.HexToHash(req.StartBlkHash)
	startStateHash := common.HexToHash(req.StartBlkStateHash)
	endBlockHash := common.HexToHash(req.EndBlkHash)
	endStateHash := common.HexToHash(req.EndBlkStateHash)
	l2Block := new(big.Int).SetUint64(req.EndBlkHeight)

	digest := computeEIP712Digest(
		domainSep,
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
