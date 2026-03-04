package erc8021

import (
	"encoding/hex"
	"fmt"
	"strings"
	"testing"
)

// buildCalldata assembles Schema 0 calldata:
//
//	txData || codes || codesLength || schemaId(0x00) || ercMarker
func buildCalldata(txData []byte, schemaID SchemaID, codes string) []byte {
	codesBytes := []byte(codes)
	var buf []byte
	buf = append(buf, txData...)
	buf = append(buf, codesBytes...)
	buf = append(buf, byte(len(codesBytes)))
	buf = append(buf, byte(schemaID))
	buf = append(buf, Marker[:]...)
	return buf
}

// buildCalldataV1 assembles Schema 1 calldata:
//
//	txData || registryAddress(20) || registryChainId || registryChainIdLength(1)
//	       || codes || codesLength(1) || schemaId(0x01) || ercMarker
func buildCalldataV1(txData []byte, codes string, registryAddress [20]byte, registryChainID []byte) []byte {
	codesBytes := []byte(codes)
	var buf []byte
	buf = append(buf, txData...)
	buf = append(buf, registryAddress[:]...)
	buf = append(buf, registryChainID...)
	buf = append(buf, byte(len(registryChainID)))
	buf = append(buf, codesBytes...)
	buf = append(buf, byte(len(codesBytes)))
	buf = append(buf, byte(SchemaCanonicalV1))
	buf = append(buf, Marker[:]...)
	return buf
}

// ── Schema 0 (Canonical Code Registry) ────────────────────────────────────

func TestParseSchema0_SingleCode(t *testing.T) {
	txData := mustDecodeHex("a9059cbb" + // transfer(address,uint256) selector
		"00000000000000000000000070997970c51812dc3a010c7d01b50e0d17dc79c8" +
		"0000000000000000000000000000000000000000000000000de0b6b3a7640000")

	calldata := buildCalldata(txData, SchemaCanonicalV0, "baseapp")

	d, err := Parse(calldata)
	if err != nil {
		t.Fatalf("Parse error: %v", err)
	}
	if !bytesEqual(d.TxData, txData) {
		t.Errorf("TxData mismatch")
	}
	if d.Attribution.SchemaID != SchemaCanonicalV0 {
		t.Errorf("SchemaID: want 0x00, got 0x%02x", d.Attribution.SchemaID)
	}

	s0, err := d.Attribution.DecodeSchema0()
	if err != nil {
		t.Fatalf("DecodeSchema0 error: %v", err)
	}
	if len(s0.Codes) != 1 || s0.Codes[0] != "baseapp" {
		t.Errorf("Codes: want [baseapp], got %v", s0.Codes)
	}
}

func TestParseSchema0_MultipleCodes(t *testing.T) {
	txData := []byte{0xde, 0xad, 0xbe, 0xef}
	calldata := buildCalldata(txData, SchemaCanonicalV0, "baseapp,relayer,myapp")

	d, err := Parse(calldata)
	if err != nil {
		t.Fatalf("Parse error: %v", err)
	}
	s0, err := d.Attribution.DecodeSchema0()
	if err != nil {
		t.Fatalf("DecodeSchema0 error: %v", err)
	}
	want := []string{"baseapp", "relayer", "myapp"}
	if len(s0.Codes) != len(want) {
		t.Fatalf("len(Codes): want %d, got %d", len(want), len(s0.Codes))
	}
	for i, c := range want {
		if s0.Codes[i] != c {
			t.Errorf("Codes[%d]: want %q, got %q", i, c, s0.Codes[i])
		}
	}
}

// ── Schema 1 (Custom Code Registry) ──────────────────────────────────────

func TestParseSchema1_SingleCode(t *testing.T) {
	txData := []byte{0x01, 0x02}
	addr := [20]byte{0xAA, 0xBB, 0xCC}
	chainID := []byte{0x00, 0x00, 0x21, 0x05} // 8453 = Base mainnet (big-endian)

	calldata := buildCalldataV1(txData, "myapp", addr, chainID)

	d, err := Parse(calldata)
	if err != nil {
		t.Fatalf("Parse error: %v", err)
	}
	if d.Attribution.SchemaID != SchemaCanonicalV1 {
		t.Errorf("SchemaID: want 0x01, got 0x%02x", d.Attribution.SchemaID)
	}
	if !bytesEqual(d.TxData, txData) {
		t.Errorf("TxData mismatch: got %x, want %x", d.TxData, txData)
	}

	s1, err := d.Attribution.DecodeSchema1()
	if err != nil {
		t.Fatalf("DecodeSchema1 error: %v", err)
	}
	if len(s1.Codes) != 1 || s1.Codes[0] != "myapp" {
		t.Errorf("Codes: want [myapp], got %v", s1.Codes)
	}
	if s1.RegistryAddress != addr {
		t.Errorf("RegistryAddress: want %x, got %x", addr, s1.RegistryAddress)
	}
	if !bytesEqual(s1.RegistryChainID, chainID) {
		t.Errorf("RegistryChainID: want %x, got %x", chainID, s1.RegistryChainID)
	}
}

func TestParseSchema1_MultipleCodes(t *testing.T) {
	txData := []byte{0xde, 0xad, 0xbe, 0xef}
	addr := [20]byte{0x11, 0x22, 0x33}
	chainID := []byte{0x01} // chain 1 (Ethereum mainnet)

	calldata := buildCalldataV1(txData, "baseapp,relayer", addr, chainID)

	d, err := Parse(calldata)
	if err != nil {
		t.Fatalf("Parse error: %v", err)
	}
	s1, err := d.Attribution.DecodeSchema1()
	if err != nil {
		t.Fatalf("DecodeSchema1 error: %v", err)
	}
	want := []string{"baseapp", "relayer"}
	if len(s1.Codes) != len(want) {
		t.Fatalf("len(Codes): want %d, got %d", len(want), len(s1.Codes))
	}
	for i, c := range want {
		if s1.Codes[i] != c {
			t.Errorf("Codes[%d]: want %q, got %q", i, c, s1.Codes[i])
		}
	}
	if !bytesEqual(s1.RegistryChainID, chainID) {
		t.Errorf("RegistryChainID mismatch")
	}
}

func TestParseSchema1_CrossChain(t *testing.T) {
	// Simulate a multi-chain app referencing a registry on Optimism (chain 10).
	txData := []byte{0xCA, 0xFE}
	var addr [20]byte
	addr[19] = 0x42         // minimal non-zero address
	chainID := []byte{0x0A} // chain 10

	calldata := buildCalldataV1(txData, "crossapp", addr, chainID)

	d, err := Parse(calldata)
	if err != nil {
		t.Fatalf("Parse error: %v", err)
	}
	if !bytesEqual(d.TxData, txData) {
		t.Errorf("TxData mismatch")
	}
	s1, err := d.Attribution.DecodeSchema1()
	if err != nil {
		t.Fatalf("DecodeSchema1 error: %v", err)
	}
	if s1.Codes[0] != "crossapp" {
		t.Errorf("code: want crossapp, got %q", s1.Codes[0])
	}
	if s1.RegistryChainID[0] != 0x0A {
		t.Errorf("RegistryChainID: want 0x0A, got %x", s1.RegistryChainID)
	}
}

// ── ParseHex ──────────────────────────────────────────────────────────────

func TestParseHex_WithPrefix(t *testing.T) {
	txData := []byte{0xCA, 0xFE}
	raw := buildCalldata(txData, SchemaCanonicalV0, "test")
	hexStr := "0x" + hex.EncodeToString(raw)

	d, err := ParseHex(hexStr)
	if err != nil {
		t.Fatalf("ParseHex error: %v", err)
	}
	s0, _ := d.Attribution.DecodeSchema0()
	if s0.Codes[0] != "test" {
		t.Errorf("code: want test, got %q", s0.Codes[0])
	}
}

func TestParseHex_WithoutPrefix(t *testing.T) {
	txData := []byte{0x11}
	raw := buildCalldata(txData, SchemaCanonicalV0, "abc")
	hexStr := hex.EncodeToString(raw) // no 0x

	_, err := ParseHex(hexStr)
	if err != nil {
		t.Fatalf("ParseHex (no prefix) error: %v", err)
	}
}

// ── Error cases ───────────────────────────────────────────────────────────

func TestParse_TooShort(t *testing.T) {
	_, err := Parse([]byte{0x01, 0x02})
	if err == nil {
		t.Fatal("expected error for too-short calldata")
	}
}

func TestParse_NoMarker(t *testing.T) {
	data := make([]byte, 30) // valid length but wrong bytes
	_, err := Parse(data)
	if err == nil {
		t.Fatal("expected error when marker is absent")
	}
	if !strings.Contains(err.Error(), "marker not found") {
		t.Errorf("unexpected error message: %v", err)
	}
}

func TestParse_EmptyCodes(t *testing.T) {
	txData := []byte{0xAB, 0xCD}
	calldata := buildCalldata(txData, SchemaCanonicalV0, "")

	d, err := Parse(calldata)
	if err != nil {
		t.Fatalf("Parse error: %v", err)
	}
	s0, err := d.Attribution.DecodeSchema0()
	if err != nil {
		t.Fatalf("DecodeSchema0 error: %v", err)
	}
	if len(s0.Codes) != 0 {
		t.Errorf("expected no codes, got %v", s0.Codes)
	}
}

func TestDecodeSchema0_WrongSchema(t *testing.T) {
	a := Attribution{SchemaID: SchemaCanonicalV1, Payload: []byte("baseapp")}
	_, err := a.DecodeSchema0()
	if err == nil {
		t.Fatal("expected error when decoding wrong schema")
	}
}

func TestDecodeSchema1_WrongSchema(t *testing.T) {
	a := Attribution{SchemaID: SchemaCanonicalV0, Payload: []byte("app=x")}
	_, err := a.DecodeSchema1()
	if err == nil {
		t.Fatal("expected error when decoding wrong schema")
	}
}

// ── HasMarker ─────────────────────────────────────────────────────────────

func TestHasMarker(t *testing.T) {
	raw := buildCalldata([]byte{0x01}, SchemaCanonicalV0, "x")
	if !HasMarker(raw) {
		t.Error("HasMarker should return true")
	}
	if HasMarker([]byte{0x01, 0x02, 0x03}) {
		t.Error("HasMarker should return false for plain data")
	}
}

// ── helpers ───────────────────────────────────────────────────────────────

func mustDecodeHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

func TestMainNetData(t *testing.T) {
	hexcalldata := "0x74657374040080218021802180218021802180218021"
	d, err := ParseHex(hexcalldata)
	if err != nil {
		t.Fatalf("ParseHex error: %v", err)
	}
	s0, err := d.Attribution.DecodeSchema0()
	if err != nil {
		t.Fatalf("DecodeSchema0 error: %v", err)
	}
	fmt.Println(s0)

	// Schema1

	hexcalldataV1 := "0x00a3b805dbf39e5d54f9d09c130ff2132b4a0a2107a00274657374040180218021802180218021802180218021"
	d, err = ParseHex(hexcalldataV1)
	if err != nil {
		t.Fatalf("ParseHex error: %v", err)
	}
	s1, err := d.Attribution.DecodeSchema1()
	if err != nil {
		t.Fatalf("DecodeSchema1 error: %v", err)
	}
	fmt.Println(s1)

}
