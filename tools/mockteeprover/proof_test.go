package main

import (
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

func TestGenerateProofBytes(t *testing.T) {
	// Generate a test signer key
	signerKey, err := crypto.GenerateKey()
	if err != nil {
		t.Fatalf("failed to generate key: %v", err)
	}
	signerAddr := crypto.PubkeyToAddress(signerKey.PublicKey)

	req := ProveRequest{
		StartBlkHeight:    100,
		EndBlkHeight:      200,
		StartBlkHash:      "0x" + common.Bytes2Hex(common.LeftPadBytes([]byte{0x01}, 32)),
		EndBlkHash:        "0x" + common.Bytes2Hex(common.LeftPadBytes([]byte{0x02}, 32)),
		StartBlkStateHash: "0x" + common.Bytes2Hex(common.LeftPadBytes([]byte{0x03}, 32)),
		EndBlkStateHash:   "0x" + common.Bytes2Hex(common.LeftPadBytes([]byte{0x04}, 32)),
	}

	proofBytes, err := generateProofBytes(req, signerKey)
	if err != nil {
		t.Fatalf("generateProofBytes failed: %v", err)
	}

	if len(proofBytes) == 0 {
		t.Fatal("proofBytes is empty")
	}

	// Decode using abi.ConvertType to a known Go type
	decoded, err := batchProofABIType.Unpack(proofBytes)
	if err != nil {
		t.Fatalf("failed to unpack proofBytes: %v", err)
	}

	var proofs []BatchProof
	if err := batchProofABIType.Copy(&proofs, decoded); err != nil {
		t.Fatalf("failed to copy decoded proofs: %v", err)
	}

	if len(proofs) != 1 {
		t.Fatalf("expected 1 proof, got %d", len(proofs))
	}

	proof := proofs[0]

	// Verify l2Block
	if proof.L2Block.Uint64() != 200 {
		t.Errorf("expected l2Block=200, got %d", proof.L2Block.Uint64())
	}

	// Verify signature by recovering signer
	digest := computeBatchDigest(
		proof.StartBlockHash,
		proof.StartStateHash,
		proof.EndBlockHash,
		proof.EndStateHash,
		proof.L2Block,
	)

	// Convert v back from 27/28 to 0/1 for crypto.Ecrecover
	sig := make([]byte, 65)
	copy(sig, proof.Signature)
	sig[64] -= 27

	pubKey, err := crypto.Ecrecover(digest.Bytes(), sig)
	if err != nil {
		t.Fatalf("Ecrecover failed: %v", err)
	}
	recoveredAddr := common.BytesToAddress(crypto.Keccak256(pubKey[1:])[12:])

	if recoveredAddr != signerAddr {
		t.Errorf("recovered address %s != signer %s", recoveredAddr.Hex(), signerAddr.Hex())
	}

	t.Logf("proofBytes length: %d bytes", len(proofBytes))
	t.Logf("signer: %s, recovered: %s", signerAddr.Hex(), recoveredAddr.Hex())
}

func TestComputeBatchDigest(t *testing.T) {
	// Deterministic inputs
	startBlockHash := [32]byte{0x01}
	startStateHash := [32]byte{0x02}
	endBlockHash := [32]byte{0x03}
	endStateHash := [32]byte{0x04}
	l2Block := big.NewInt(100)

	d1 := computeBatchDigest(startBlockHash, startStateHash, endBlockHash, endStateHash, l2Block)
	d2 := computeBatchDigest(startBlockHash, startStateHash, endBlockHash, endStateHash, l2Block)

	if d1 != d2 {
		t.Error("digest should be deterministic")
	}

	// Different input should produce different digest
	d3 := computeBatchDigest(startBlockHash, startStateHash, endBlockHash, endStateHash, big.NewInt(101))
	if d1 == d3 {
		t.Error("different input should produce different digest")
	}
}

func TestSignBatchDigest(t *testing.T) {
	key, _ := crypto.GenerateKey()
	digest := common.HexToHash("0xdeadbeef")

	sig, err := signBatchDigest(digest, key)
	if err != nil {
		t.Fatalf("signBatchDigest failed: %v", err)
	}

	if len(sig) != 65 {
		t.Fatalf("expected 65 byte signature, got %d", len(sig))
	}

	// v should be 27 or 28
	if sig[64] != 27 && sig[64] != 28 {
		t.Errorf("v byte should be 27 or 28, got %d", sig[64])
	}
}
