// Package mpt implements a Merkle Patricia Trie for state commitment.
package mpt

import (
	"bytes"

	"github.com/ethereum-optimism/optimism/demo/core/types"
)

// NodeType represents the type of a trie node.
type NodeType uint8

const (
	NodeTypeEmpty     NodeType = 0
	NodeTypeLeaf      NodeType = 1
	NodeTypeBranch    NodeType = 2
	NodeTypeExtension NodeType = 3
)

// Node represents a node in the Merkle Patricia Trie.
type Node struct {
	Type     NodeType
	Key      []byte      // For leaf/extension: the remaining key nibbles
	Value    []byte      // For leaf: the value; for branch: nil
	Children [16]*Node   // For branch: 16 children (one for each hex nibble)
	hash     *types.Hash // Cached hash
}

// EmptyNode returns an empty node.
func EmptyNode() *Node {
	return &Node{Type: NodeTypeEmpty}
}

// LeafNode creates a new leaf node.
func LeafNode(key, value []byte) *Node {
	return &Node{
		Type:  NodeTypeLeaf,
		Key:   key,
		Value: value,
	}
}

// BranchNode creates a new branch node.
func BranchNode() *Node {
	return &Node{
		Type:     NodeTypeBranch,
		Children: [16]*Node{},
	}
}

// ExtensionNode creates a new extension node.
func ExtensionNode(key []byte, child *Node) *Node {
	return &Node{
		Type:     NodeTypeExtension,
		Key:      key,
		Children: [16]*Node{},
	}
}

// Hash returns the hash of the node.
func (n *Node) Hash() types.Hash {
	if n == nil || n.Type == NodeTypeEmpty {
		return types.ZeroHash
	}

	// Return cached hash if available
	if n.hash != nil {
		return *n.hash
	}

	// Compute hash based on node type
	var hash types.Hash
	switch n.Type {
	case NodeTypeLeaf:
		hash = n.hashLeaf()
	case NodeTypeBranch:
		hash = n.hashBranch()
	case NodeTypeExtension:
		hash = n.hashExtension()
	default:
		return types.ZeroHash
	}

	n.hash = &hash
	return hash
}

// hashLeaf computes the hash of a leaf node.
func (n *Node) hashLeaf() types.Hash {
	var buf bytes.Buffer
	buf.WriteByte(byte(NodeTypeLeaf))
	buf.Write(encodeLength(len(n.Key)))
	buf.Write(n.Key)
	buf.Write(encodeLength(len(n.Value)))
	buf.Write(n.Value)
	return types.Keccak256(buf.Bytes())
}

// hashBranch computes the hash of a branch node.
func (n *Node) hashBranch() types.Hash {
	var buf bytes.Buffer
	buf.WriteByte(byte(NodeTypeBranch))

	// Hash all children
	for i := 0; i < 16; i++ {
		if n.Children[i] != nil {
			childHash := n.Children[i].Hash()
			buf.Write(childHash[:])
		} else {
			buf.Write(types.ZeroHash[:])
		}
	}

	// Include value if present (for branch nodes that also store values)
	if n.Value != nil {
		buf.Write(encodeLength(len(n.Value)))
		buf.Write(n.Value)
	}

	return types.Keccak256(buf.Bytes())
}

// hashExtension computes the hash of an extension node.
func (n *Node) hashExtension() types.Hash {
	var buf bytes.Buffer
	buf.WriteByte(byte(NodeTypeExtension))
	buf.Write(encodeLength(len(n.Key)))
	buf.Write(n.Key)

	// Find the child (stored in first non-nil slot)
	for i := 0; i < 16; i++ {
		if n.Children[i] != nil {
			childHash := n.Children[i].Hash()
			buf.Write(childHash[:])
			break
		}
	}

	return types.Keccak256(buf.Bytes())
}

// InvalidateHash invalidates the cached hash.
func (n *Node) InvalidateHash() {
	n.hash = nil
}

// Clone creates a deep copy of the node.
func (n *Node) Clone() *Node {
	if n == nil {
		return nil
	}

	clone := &Node{
		Type: n.Type,
	}

	if n.Key != nil {
		clone.Key = make([]byte, len(n.Key))
		copy(clone.Key, n.Key)
	}

	if n.Value != nil {
		clone.Value = make([]byte, len(n.Value))
		copy(clone.Value, n.Value)
	}

	for i := 0; i < 16; i++ {
		if n.Children[i] != nil {
			clone.Children[i] = n.Children[i].Clone()
		}
	}

	return clone
}

// encodeLength encodes a length as a variable-length integer.
func encodeLength(n int) []byte {
	if n < 128 {
		return []byte{byte(n)}
	}
	var buf []byte
	for n > 0 {
		buf = append([]byte{byte(n & 0x7f)}, buf...)
		n >>= 7
	}
	for i := 0; i < len(buf)-1; i++ {
		buf[i] |= 0x80
	}
	return buf
}
