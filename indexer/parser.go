package erc8021

import (
	"encoding/hex"
	"fmt"
	"strings"
)

// Parse parses ERC-8021 attribution data from raw calldata bytes.
//
// It returns an error if:
//   - the calldata is too short to contain a valid suffix, or
//   - the ERC-8021 marker is absent, or
//   - the declared codes-length exceeds the available bytes.
//
// If no ERC-8021 suffix is present, use HasMarker to check first.
func Parse(calldata []byte) (*Data, error) {
	if len(calldata) < minSuffixLen {
		return nil, fmt.Errorf("erc8021: calldata too short (%d bytes, need at least %d)", len(calldata), minSuffixLen)
	}

	// The last 16 bytes must equal the marker.
	end := len(calldata)
	if !bytesEqual(calldata[end-16:end], Marker[:]) {
		return nil, fmt.Errorf("erc8021: marker not found at end of calldata")
	}

	// Byte immediately before the marker is schemaId.
	schemaID := SchemaID(calldata[end-17])

	// Byte before that is codesLength.
	codesLen := int(calldata[end-18])

	suffixLen := minSuffixLen + codesLen // 18 + codesLen
	if len(calldata) < suffixLen {
		return nil, fmt.Errorf("erc8021: calldata too short for declared codesLength=%d", codesLen)
	}

	// Extract the codes payload.
	codesStart := end - 16 - 1 - 1 - codesLen // end - marker - schemaId - codesLength - codes
	payload := make([]byte, codesLen)
	copy(payload, calldata[codesStart:codesStart+codesLen])

	attr := Attribution{
		SchemaID: schemaID,
		Payload:  payload,
	}

	// Schema 1 extends the suffix with three more fields that sit immediately
	// to the left of the codes field (right-to-left reading order):
	//   codeRegistryChainIdLength (1 byte)
	//   codeRegistryChainId       (codeRegistryChainIdLength bytes)
	//   codeRegistryAddress       (20 bytes)
	txDataEnd := codesStart
	if schemaID == SchemaCanonicalV1 {
		// Need at least 1 (chainIdLen) + 0 (chainId) + 20 (address) bytes.
		if txDataEnd < 21 {
			return nil, fmt.Errorf("erc8021: Schema 1 suffix too short for registry fields")
		}
		chainIdLen := int(calldata[txDataEnd-1])
		if txDataEnd < 1+chainIdLen+20 {
			return nil, fmt.Errorf("erc8021: Schema 1: not enough bytes for codeRegistryChainId (len=%d)", chainIdLen)
		}
		// Parse right-to-left within the remaining prefix.
		addrEnd := txDataEnd - 1 - chainIdLen       // end of address block
		addrStart := addrEnd - 20                    // start of address block
		chainIdStart := txDataEnd - 1 - chainIdLen  // start of chainId block
		if addrStart < 0 {
			return nil, fmt.Errorf("erc8021: Schema 1: not enough bytes for codeRegistryAddress")
		}
		attr.RegistryChainID = make([]byte, chainIdLen)
		copy(attr.RegistryChainID, calldata[chainIdStart:chainIdStart+chainIdLen])
		copy(attr.RegistryAddress[:], calldata[addrStart:addrStart+20])
		txDataEnd = addrStart
	}

	txData := make([]byte, txDataEnd)
	copy(txData, calldata[:txDataEnd])

	return &Data{
		TxData:      txData,
		Attribution: attr,
	}, nil
}

// ParseHex parses ERC-8021 attribution data from a hex-encoded calldata string.
// The string may optionally be prefixed with "0x" or "0X".
func ParseHex(calldataHex string) (*Data, error) {
	b, err := decodeHex(calldataHex)
	if err != nil {
		return nil, fmt.Errorf("erc8021: %w", err)
	}
	return Parse(b)
}

// HasMarker reports whether the calldata ends with the ERC-8021 marker.
func HasMarker(calldata []byte) bool {
	if len(calldata) < 16 {
		return false
	}
	return bytesEqual(calldata[len(calldata)-16:], Marker[:])
}

// DecodeSchema0 decodes the Attribution payload as SchemaCanonicalV0 (0x00).
// The payload is interpreted as a comma-delimited ASCII string.
func (a Attribution) DecodeSchema0() (*Schema0, error) {
	if a.SchemaID != SchemaCanonicalV0 {
		return nil, fmt.Errorf("erc8021: expected schemaId 0x00, got 0x%02x", a.SchemaID)
	}
	raw := string(a.Payload)
	if raw == "" {
		return &Schema0{Codes: []string{}}, nil
	}
	parts := strings.Split(raw, ",")
	codes := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			codes = append(codes, p)
		}
	}
	return &Schema0{Codes: codes}, nil
}

// DecodeSchema1 decodes the Attribution as SchemaCanonicalV1 (0x01).
// The codes payload is interpreted as a comma-delimited ASCII string;
// the registry chain id and address come from the Attribution fields
// populated during Parse.
func (a Attribution) DecodeSchema1() (*Schema1, error) {
	if a.SchemaID != SchemaCanonicalV1 {
		return nil, fmt.Errorf("erc8021: expected schemaId 0x01, got 0x%02x", a.SchemaID)
	}
	var codes []string
	if raw := string(a.Payload); raw != "" {
		for _, p := range strings.Split(raw, ",") {
			p = strings.TrimSpace(p)
			if p != "" {
				codes = append(codes, p)
			}
		}
	}
	return &Schema1{
		Codes:           codes,
		RegistryChainID: a.RegistryChainID,
		RegistryAddress: a.RegistryAddress,
	}, nil
}

// PayloadHex returns the Attribution payload as a "0x"-prefixed hex string.
func (a Attribution) PayloadHex() string {
	return "0x" + hex.EncodeToString(a.Payload)
}

// TxDataHex returns the TxData field as a "0x"-prefixed hex string.
func (d *Data) TxDataHex() string {
	return "0x" + hex.EncodeToString(d.TxData)
}

// ── helpers ────────────────────────────────────────────────────────────────

func decodeHex(s string) ([]byte, error) {
	s = strings.TrimPrefix(s, "0x")
	s = strings.TrimPrefix(s, "0X")
	b, err := hex.DecodeString(s)
	if err != nil {
		return nil, fmt.Errorf("invalid hex string: %w", err)
	}
	return b, nil
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
