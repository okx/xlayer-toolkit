// Package mpt implements Merkle proofs for the trie.
package mpt

import (
	"bytes"
	"errors"

	"github.com/ethereum-optimism/optimism/demo/core/types"
)

// ProofNode represents a node in a Merkle proof.
type ProofNode struct {
	Type     NodeType
	Key      []byte
	Value    []byte
	Children [16]types.Hash // Hashes of children
}

// Proof represents a Merkle proof for a key-value pair.
type Proof struct {
	Key   []byte
	Value []byte
	Nodes []ProofNode
}

// Prove generates a Merkle proof for a key.
func (t *Trie) Prove(key []byte) (*Proof, error) {
	nibbles := keyToNibbles(key)
	proof := &Proof{
		Key:   key,
		Nodes: make([]ProofNode, 0),
	}

	found := t.prove(t.root, nibbles, proof)
	if !found {
		return nil, errors.New("key not found")
	}

	return proof, nil
}

// prove recursively builds a proof.
func (t *Trie) prove(node *Node, nibbles []byte, proof *Proof) bool {
	if node == nil || node.Type == NodeTypeEmpty {
		return false
	}

	switch node.Type {
	case NodeTypeLeaf:
		if bytes.Equal(node.Key, nibbles) {
			proof.Value = node.Value
			proof.Nodes = append(proof.Nodes, ProofNode{
				Type:  NodeTypeLeaf,
				Key:   node.Key,
				Value: node.Value,
			})
			return true
		}
		return false

	case NodeTypeBranch:
		pn := ProofNode{
			Type:  NodeTypeBranch,
			Value: node.Value,
		}
		for i := 0; i < 16; i++ {
			if node.Children[i] != nil {
				pn.Children[i] = node.Children[i].Hash()
			}
		}
		proof.Nodes = append(proof.Nodes, pn)

		if len(nibbles) == 0 {
			proof.Value = node.Value
			return node.Value != nil
		}
		return t.prove(node.Children[nibbles[0]], nibbles[1:], proof)

	case NodeTypeExtension:
		if len(nibbles) < len(node.Key) || !bytes.Equal(nibbles[:len(node.Key)], node.Key) {
			return false
		}

		pn := ProofNode{
			Type: NodeTypeExtension,
			Key:  node.Key,
		}
		for i := 0; i < 16; i++ {
			if node.Children[i] != nil {
				pn.Children[i] = node.Children[i].Hash()
				proof.Nodes = append(proof.Nodes, pn)
				return t.prove(node.Children[i], nibbles[len(node.Key):], proof)
			}
		}
	}

	return false
}

// VerifyProof verifies a Merkle proof against a root hash.
func VerifyProof(root types.Hash, proof *Proof) bool {
	if len(proof.Nodes) == 0 {
		return false
	}

	// Reconstruct and verify from leaf to root
	nibbles := keyToNibbles(proof.Key)
	computedRoot := verifyProofNodes(proof.Nodes, nibbles, 0)

	return computedRoot == root
}

// verifyProofNodes recursively verifies proof nodes.
func verifyProofNodes(nodes []ProofNode, nibbles []byte, idx int) types.Hash {
	if idx >= len(nodes) {
		return types.ZeroHash
	}

	node := nodes[idx]

	switch node.Type {
	case NodeTypeLeaf:
		// Verify the leaf
		var buf bytes.Buffer
		buf.WriteByte(byte(NodeTypeLeaf))
		buf.Write(encodeLength(len(node.Key)))
		buf.Write(node.Key)
		buf.Write(encodeLength(len(node.Value)))
		buf.Write(node.Value)
		return types.Keccak256(buf.Bytes())

	case NodeTypeBranch:
		var buf bytes.Buffer
		buf.WriteByte(byte(NodeTypeBranch))

		for i := 0; i < 16; i++ {
			if len(nibbles) > 0 && i == int(nibbles[0]) && idx+1 < len(nodes) {
				// This is the path we're proving - compute from next node
				childHash := verifyProofNodes(nodes, nibbles[1:], idx+1)
				buf.Write(childHash[:])
			} else {
				buf.Write(node.Children[i][:])
			}
		}

		if node.Value != nil {
			buf.Write(encodeLength(len(node.Value)))
			buf.Write(node.Value)
		}

		return types.Keccak256(buf.Bytes())

	case NodeTypeExtension:
		var buf bytes.Buffer
		buf.WriteByte(byte(NodeTypeExtension))
		buf.Write(encodeLength(len(node.Key)))
		buf.Write(node.Key)

		// Compute child hash
		childHash := verifyProofNodes(nodes, nibbles[len(node.Key):], idx+1)
		buf.Write(childHash[:])

		return types.Keccak256(buf.Bytes())
	}

	return types.ZeroHash
}

// ProofToBytes serializes a proof to bytes.
func (p *Proof) ToBytes() []byte {
	var buf bytes.Buffer

	// Write key
	buf.Write(encodeLength(len(p.Key)))
	buf.Write(p.Key)

	// Write value
	buf.Write(encodeLength(len(p.Value)))
	buf.Write(p.Value)

	// Write nodes count
	buf.Write(encodeLength(len(p.Nodes)))

	// Write each node
	for _, node := range p.Nodes {
		buf.WriteByte(byte(node.Type))

		buf.Write(encodeLength(len(node.Key)))
		buf.Write(node.Key)

		buf.Write(encodeLength(len(node.Value)))
		buf.Write(node.Value)

		for i := 0; i < 16; i++ {
			buf.Write(node.Children[i][:])
		}
	}

	return buf.Bytes()
}
