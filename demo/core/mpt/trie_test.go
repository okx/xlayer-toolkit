package mpt

import (
	"bytes"
	"testing"

	"github.com/ethereum-optimism/optimism/demo/core/types"
)

func TestTrieBasic(t *testing.T) {
	trie := New()

	// Test empty trie
	if trie.Root() != types.ZeroHash {
		t.Error("Empty trie should have zero hash")
	}

	// Insert single value
	trie.Insert([]byte("hello"), []byte("world"))
	root1 := trie.Root()

	if root1 == types.ZeroHash {
		t.Error("Trie with data should not have zero hash")
	}

	// Get value
	value := trie.Get([]byte("hello"))
	if !bytes.Equal(value, []byte("world")) {
		t.Errorf("Got %s, want world", value)
	}

	// Get non-existent key
	value = trie.Get([]byte("notexist"))
	if value != nil {
		t.Error("Should return nil for non-existent key")
	}
}

func TestTrieMultipleKeys(t *testing.T) {
	trie := New()

	// Insert multiple values
	testData := map[string]string{
		"apple":  "fruit",
		"banana": "yellow",
		"cherry": "red",
		"date":   "sweet",
		"app":    "application",
		"apply":  "verb",
	}

	for k, v := range testData {
		trie.Insert([]byte(k), []byte(v))
	}

	// Verify all values
	for k, v := range testData {
		got := trie.Get([]byte(k))
		if !bytes.Equal(got, []byte(v)) {
			t.Errorf("Key %s: got %s, want %s", k, got, v)
		}
	}

	// Root should be deterministic
	root := trie.Root()
	t.Logf("Trie root: %x", root)
}

func TestTrieUpdate(t *testing.T) {
	trie := New()

	// Insert
	trie.Insert([]byte("key"), []byte("value1"))
	root1 := trie.Root()

	// Update
	trie.Insert([]byte("key"), []byte("value2"))
	root2 := trie.Root()

	// Roots should be different
	if root1 == root2 {
		t.Error("Root should change after update")
	}

	// Value should be updated
	value := trie.Get([]byte("key"))
	if !bytes.Equal(value, []byte("value2")) {
		t.Errorf("Got %s, want value2", value)
	}
}

func TestTrieDelete(t *testing.T) {
	trie := New()

	// Insert
	trie.Insert([]byte("key1"), []byte("value1"))
	trie.Insert([]byte("key2"), []byte("value2"))
	trie.Insert([]byte("key3"), []byte("value3"))

	// Delete
	deleted := trie.Delete([]byte("key2"))
	if !deleted {
		t.Error("Delete should return true")
	}

	// Verify deletion
	value := trie.Get([]byte("key2"))
	if value != nil {
		t.Error("Deleted key should return nil")
	}

	// Other keys should still exist
	if trie.Get([]byte("key1")) == nil {
		t.Error("key1 should still exist")
	}
	if trie.Get([]byte("key3")) == nil {
		t.Error("key3 should still exist")
	}
}

func TestTrieProof(t *testing.T) {
	trie := New()

	// Insert data
	trie.Insert([]byte("hello"), []byte("world"))
	trie.Insert([]byte("foo"), []byte("bar"))
	trie.Insert([]byte("test"), []byte("data"))

	root := trie.Root()

	// Generate proof for "hello"
	proof, err := trie.Prove([]byte("hello"))
	if err != nil {
		t.Fatalf("Failed to generate proof: %v", err)
	}

	// Verify value in proof
	if !bytes.Equal(proof.Value, []byte("world")) {
		t.Errorf("Proof value mismatch: got %s, want world", proof.Value)
	}

	// Verify proof
	if !VerifyProof(root, proof) {
		t.Error("Proof verification failed")
	}

	t.Logf("Proof has %d nodes", len(proof.Nodes))
}

func TestTrieDeterminism(t *testing.T) {
	// Two tries with same data in different order should have same root
	trie1 := New()
	trie1.Insert([]byte("a"), []byte("1"))
	trie1.Insert([]byte("b"), []byte("2"))
	trie1.Insert([]byte("c"), []byte("3"))

	trie2 := New()
	trie2.Insert([]byte("c"), []byte("3"))
	trie2.Insert([]byte("a"), []byte("1"))
	trie2.Insert([]byte("b"), []byte("2"))

	if trie1.Root() != trie2.Root() {
		t.Error("Tries with same data should have same root")
	}
}

func TestTrieClone(t *testing.T) {
	trie := New()
	trie.Insert([]byte("key"), []byte("value"))
	root1 := trie.Root()

	// Clone
	clone := trie.Clone()

	// Modify original
	trie.Insert([]byte("key2"), []byte("value2"))

	// Clone should be unchanged
	if clone.Root() != root1 {
		t.Error("Clone should not be affected by original modification")
	}

	// Clone should still have original data
	if !bytes.Equal(clone.Get([]byte("key")), []byte("value")) {
		t.Error("Clone should have original data")
	}

	// Clone should not have new data
	if clone.Get([]byte("key2")) != nil {
		t.Error("Clone should not have new data")
	}
}

func TestNibbleConversion(t *testing.T) {
	original := []byte{0xab, 0xcd, 0xef}
	nibbles := keyToNibbles(original)

	expected := []byte{0xa, 0xb, 0xc, 0xd, 0xe, 0xf}
	if !bytes.Equal(nibbles, expected) {
		t.Errorf("Nibbles mismatch: got %v, want %v", nibbles, expected)
	}

	// Convert back
	key := nibblesToKey(nibbles)
	if !bytes.Equal(key, original) {
		t.Errorf("Key mismatch: got %v, want %v", key, original)
	}
}
