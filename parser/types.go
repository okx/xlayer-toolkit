// Package erc8021 provides parsing utilities for ERC-8021 attribution calldata.
//
// ERC-8021 appends a schema-specific suffix to transaction calldata so that
// indexers can attribute on-chain activity to application builders.
//
// Schema 0 suffix layout (right-to-left from end of calldata):
//
//	ercMarker   (16 bytes) : 0x80218021802180218021802180218021
//	schemaId    (1  byte)  : 0x00
//	codesLength (1  byte)  : byte length of the codes field
//	codes       (variable) : comma-delimited ASCII builder codes
//
// Schema 1 suffix layout (right-to-left from end of calldata):
//
//	ercMarker                (16 bytes) : 0x80218021802180218021802180218021
//	schemaId                 (1  byte)  : 0x01
//	codesLength              (1  byte)  : byte length of the codes field
//	codes                    (variable) : comma-delimited ASCII builder codes
//	codeRegistryChainIdLength(1  byte)  : byte length of the chain-id field
//	codeRegistryChainId      (variable) : chain id of the custom Code Registry
//	codeRegistryAddress      (20 bytes) : ICodeRegistry contract address
package erc8021

import "strings"

// Marker is the 16-byte magic that terminates every ERC-8021 suffix.
var Marker = [16]byte{
	0x80, 0x21, 0x80, 0x21, 0x80, 0x21, 0x80, 0x21,
	0x80, 0x21, 0x80, 0x21, 0x80, 0x21, 0x80, 0x21,
}

// MarkerHex is the lower-case hex encoding of Marker (no 0x prefix).
const MarkerHex = "80218021802180218021802180218021"

// Minimum byte count for a valid ERC-8021 suffix:
// marker(16) + schemaId(1) + codesLength(1) = 18 bytes.
const minSuffixLen = 18

// SchemaID identifies the attribution encoding used in the codes field.
type SchemaID uint8

const (
	// SchemaCanonicalV0 (0x00) – Canonical Code Registry.
	// The codes field is a comma-delimited ASCII string of registered builder
	// codes, e.g. "baseapp" or "baseapp,relayer".
	SchemaCanonicalV0 SchemaID = 0x00

	// SchemaCanonicalV1 (0x01) – Custom Code Registry.
	// Extends Schema 0 with a custom on-chain Code Registry: the suffix also
	// includes the registry's chain id and contract address so that codes can
	// be resolved against any ICodeRegistry deployment across chains.
	SchemaCanonicalV1 SchemaID = 0x01
)

// Data is the fully parsed representation of an ERC-8021-tagged calldata.
type Data struct {
	// TxData is the original transaction input before the ERC-8021 suffix.
	TxData []byte

	// Attribution holds the decoded ERC-8021 metadata.
	Attribution Attribution
}

// Attribution is the decoded ERC-8021 suffix.
type Attribution struct {
	// SchemaID identifies the schema used in this suffix.
	SchemaID SchemaID

	// Payload is the raw bytes of the codes field (comma-delimited ASCII).
	Payload []byte

	// Schema 1 only: raw bytes of the codeRegistryChainId field.
	// Nil for Schema 0.
	RegistryChainID []byte

	// Schema 1 only: address of the ICodeRegistry contract.
	// Zero value for Schema 0.
	RegistryAddress [20]byte
}

// Schema0 is the structured attribution for SchemaCanonicalV0 (0x00).
// Codes is the comma-delimited list of builder attribution codes.
type Schema0 struct {
	Codes []string
}

// String returns the codes as a comma-joined string.
func (s Schema0) String() string { return strings.Join(s.Codes, ",") }

// Schema1 is the structured attribution for SchemaCanonicalV1 (0x01).
// It extends Schema 0 with a reference to a custom on-chain Code Registry.
type Schema1 struct {
	// Codes is the comma-delimited list of builder attribution codes.
	Codes []string

	// RegistryChainID is the raw bytes of the chain id that hosts the
	// custom Code Registry (big-endian, variable length).
	RegistryChainID []byte

	// RegistryAddress is the ICodeRegistry contract address on RegistryChainID.
	RegistryAddress [20]byte
}
