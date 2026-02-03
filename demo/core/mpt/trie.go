// Package mpt implements a Merkle Patricia Trie for state commitment.
package mpt

import (
	"bytes"

	"github.com/ethereum-optimism/optimism/demo/core/types"
)

// Trie represents a Merkle Patricia Trie.
type Trie struct {
	root *Node
}

// New creates a new empty trie.
func New() *Trie {
	return &Trie{
		root: EmptyNode(),
	}
}

// Root returns the root hash of the trie.
func (t *Trie) Root() types.Hash {
	if t.root == nil {
		return types.ZeroHash
	}
	return t.root.Hash()
}

// Get retrieves the value for a key.
func (t *Trie) Get(key []byte) []byte {
	nibbles := keyToNibbles(key)
	return t.get(t.root, nibbles)
}

// get recursively searches for a key.
func (t *Trie) get(node *Node, nibbles []byte) []byte {
	if node == nil || node.Type == NodeTypeEmpty {
		return nil
	}

	switch node.Type {
	case NodeTypeLeaf:
		if bytes.Equal(node.Key, nibbles) {
			return node.Value
		}
		return nil

	case NodeTypeBranch:
		if len(nibbles) == 0 {
			return node.Value
		}
		return t.get(node.Children[nibbles[0]], nibbles[1:])

	case NodeTypeExtension:
		if len(nibbles) < len(node.Key) || !bytes.Equal(nibbles[:len(node.Key)], node.Key) {
			return nil
		}
		// Find child
		for i := 0; i < 16; i++ {
			if node.Children[i] != nil {
				return t.get(node.Children[i], nibbles[len(node.Key):])
			}
		}
		return nil
	}

	return nil
}

// Insert inserts a key-value pair into the trie.
func (t *Trie) Insert(key, value []byte) {
	nibbles := keyToNibbles(key)
	t.root = t.insert(t.root, nibbles, value)
}

// insert recursively inserts a key-value pair.
func (t *Trie) insert(node *Node, nibbles, value []byte) *Node {
	if node == nil || node.Type == NodeTypeEmpty {
		return LeafNode(nibbles, value)
	}

	switch node.Type {
	case NodeTypeLeaf:
		return t.insertIntoLeaf(node, nibbles, value)

	case NodeTypeBranch:
		return t.insertIntoBranch(node, nibbles, value)

	case NodeTypeExtension:
		return t.insertIntoExtension(node, nibbles, value)
	}

	return node
}

// insertIntoLeaf handles insertion into a leaf node.
func (t *Trie) insertIntoLeaf(node *Node, nibbles, value []byte) *Node {
	// If same key, update value
	if bytes.Equal(node.Key, nibbles) {
		node.Value = value
		node.InvalidateHash()
		return node
	}

	// Find common prefix
	commonLen := commonPrefixLength(node.Key, nibbles)

	// Create new branch node
	branch := BranchNode()

	// Handle remaining nibbles from old leaf
	oldRemaining := node.Key[commonLen:]
	if len(oldRemaining) == 0 {
		branch.Value = node.Value
	} else {
		branch.Children[oldRemaining[0]] = LeafNode(oldRemaining[1:], node.Value)
	}

	// Handle remaining nibbles from new key
	newRemaining := nibbles[commonLen:]
	if len(newRemaining) == 0 {
		branch.Value = value
	} else {
		branch.Children[newRemaining[0]] = LeafNode(newRemaining[1:], value)
	}

	// If there's a common prefix, create extension node
	if commonLen > 0 {
		ext := &Node{
			Type: NodeTypeExtension,
			Key:  nibbles[:commonLen],
		}
		ext.Children[0] = branch
		return ext
	}

	return branch
}

// insertIntoBranch handles insertion into a branch node.
func (t *Trie) insertIntoBranch(node *Node, nibbles, value []byte) *Node {
	node.InvalidateHash()

	if len(nibbles) == 0 {
		node.Value = value
		return node
	}

	idx := nibbles[0]
	node.Children[idx] = t.insert(node.Children[idx], nibbles[1:], value)
	return node
}

// insertIntoExtension handles insertion into an extension node.
func (t *Trie) insertIntoExtension(node *Node, nibbles, value []byte) *Node {
	commonLen := commonPrefixLength(node.Key, nibbles)

	// If nibbles fully match extension key, recurse into child
	if commonLen == len(node.Key) {
		node.InvalidateHash()
		// Find child and recurse
		for i := 0; i < 16; i++ {
			if node.Children[i] != nil {
				node.Children[i] = t.insert(node.Children[i], nibbles[commonLen:], value)
				return node
			}
		}
	}

	// Need to split the extension
	branch := BranchNode()

	// Handle old extension's remaining path
	if commonLen < len(node.Key) {
		oldRemaining := node.Key[commonLen:]
		if len(oldRemaining) == 1 {
			// Just one nibble remaining, put child directly in branch
			for i := 0; i < 16; i++ {
				if node.Children[i] != nil {
					branch.Children[oldRemaining[0]] = node.Children[i]
					break
				}
			}
		} else {
			// More than one nibble, create new extension
			newExt := &Node{
				Type: NodeTypeExtension,
				Key:  oldRemaining[1:],
			}
			for i := 0; i < 16; i++ {
				if node.Children[i] != nil {
					newExt.Children[0] = node.Children[i]
					break
				}
			}
			branch.Children[oldRemaining[0]] = newExt
		}
	}

	// Handle new key's remaining path
	newRemaining := nibbles[commonLen:]
	if len(newRemaining) == 0 {
		branch.Value = value
	} else {
		branch.Children[newRemaining[0]] = t.insert(nil, newRemaining[1:], value)
	}

	// If there's a common prefix, create new extension
	if commonLen > 0 {
		ext := &Node{
			Type: NodeTypeExtension,
			Key:  nibbles[:commonLen],
		}
		ext.Children[0] = branch
		return ext
	}

	return branch
}

// Delete removes a key from the trie.
func (t *Trie) Delete(key []byte) bool {
	nibbles := keyToNibbles(key)
	newRoot, deleted := t.delete(t.root, nibbles)
	if deleted {
		t.root = newRoot
	}
	return deleted
}

// delete recursively deletes a key.
func (t *Trie) delete(node *Node, nibbles []byte) (*Node, bool) {
	if node == nil || node.Type == NodeTypeEmpty {
		return node, false
	}

	switch node.Type {
	case NodeTypeLeaf:
		if bytes.Equal(node.Key, nibbles) {
			return EmptyNode(), true
		}
		return node, false

	case NodeTypeBranch:
		if len(nibbles) == 0 {
			if node.Value == nil {
				return node, false
			}
			node.Value = nil
			node.InvalidateHash()
			return t.compactBranch(node), true
		}

		idx := nibbles[0]
		newChild, deleted := t.delete(node.Children[idx], nibbles[1:])
		if !deleted {
			return node, false
		}

		node.Children[idx] = newChild
		node.InvalidateHash()
		return t.compactBranch(node), true

	case NodeTypeExtension:
		if len(nibbles) < len(node.Key) || !bytes.Equal(nibbles[:len(node.Key)], node.Key) {
			return node, false
		}

		for i := 0; i < 16; i++ {
			if node.Children[i] != nil {
				newChild, deleted := t.delete(node.Children[i], nibbles[len(node.Key):])
				if !deleted {
					return node, false
				}
				node.Children[i] = newChild
				node.InvalidateHash()
				return t.compactExtension(node), true
			}
		}
	}

	return node, false
}

// compactBranch compacts a branch node if possible.
func (t *Trie) compactBranch(node *Node) *Node {
	childCount := 0
	lastChildIdx := -1

	for i := 0; i < 16; i++ {
		if node.Children[i] != nil && node.Children[i].Type != NodeTypeEmpty {
			childCount++
			lastChildIdx = i
		}
	}

	// If branch has value, keep it
	if node.Value != nil {
		return node
	}

	// If no children, return empty
	if childCount == 0 {
		return EmptyNode()
	}

	// If only one child, compact
	if childCount == 1 {
		child := node.Children[lastChildIdx]
		prefix := []byte{byte(lastChildIdx)}

		switch child.Type {
		case NodeTypeLeaf:
			return LeafNode(append(prefix, child.Key...), child.Value)
		case NodeTypeExtension:
			return &Node{
				Type:     NodeTypeExtension,
				Key:      append(prefix, child.Key...),
				Children: child.Children,
			}
		default:
			ext := &Node{
				Type: NodeTypeExtension,
				Key:  prefix,
			}
			ext.Children[0] = child
			return ext
		}
	}

	return node
}

// compactExtension compacts an extension node if possible.
func (t *Trie) compactExtension(node *Node) *Node {
	var child *Node
	for i := 0; i < 16; i++ {
		if node.Children[i] != nil {
			child = node.Children[i]
			break
		}
	}

	if child == nil || child.Type == NodeTypeEmpty {
		return EmptyNode()
	}

	switch child.Type {
	case NodeTypeLeaf:
		return LeafNode(append(node.Key, child.Key...), child.Value)
	case NodeTypeExtension:
		return &Node{
			Type:     NodeTypeExtension,
			Key:      append(node.Key, child.Key...),
			Children: child.Children,
		}
	}

	return node
}

// Clear clears the trie.
func (t *Trie) Clear() {
	t.root = EmptyNode()
}

// Clone creates a deep copy of the trie.
func (t *Trie) Clone() *Trie {
	return &Trie{
		root: t.root.Clone(),
	}
}

// keyToNibbles converts a byte key to nibbles (half-bytes).
func keyToNibbles(key []byte) []byte {
	nibbles := make([]byte, len(key)*2)
	for i, b := range key {
		nibbles[i*2] = b >> 4
		nibbles[i*2+1] = b & 0x0f
	}
	return nibbles
}

// nibblesToKey converts nibbles back to bytes.
func nibblesToKey(nibbles []byte) []byte {
	if len(nibbles)%2 != 0 {
		nibbles = append(nibbles, 0)
	}
	key := make([]byte, len(nibbles)/2)
	for i := 0; i < len(key); i++ {
		key[i] = (nibbles[i*2] << 4) | nibbles[i*2+1]
	}
	return key
}

// commonPrefixLength returns the length of the common prefix.
func commonPrefixLength(a, b []byte) int {
	minLen := len(a)
	if len(b) < minLen {
		minLen = len(b)
	}
	for i := 0; i < minLen; i++ {
		if a[i] != b[i] {
			return i
		}
	}
	return minLen
}
