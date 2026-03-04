// Command erc8021 fetches a transaction by hash, parses its ERC-8021
// attribution suffix, and optionally queries the on-chain BuilderCodes registry.
//
// Usage:
//
//	erc8021 -txhash <0x…> [-rpc <url>] [-ca <0x…>]
//
// Flags:
//
//	-txhash  Transaction hash to inspect (required).
//	-rpc     JSON-RPC endpoint for the chain the tx was sent on
//	         (default: http://localhost:8545).
//	-ca      BuilderCodes registry contract address.
//	         Required for Schema 0 registry lookup.
//	         For Schema 1 the address embedded in the calldata is used;
//	         -ca is ignored in that case.
package main

import (
	"context"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"strings"

	erc8021 "erc8021"
)

func main() {
	txHash := flag.String("txhash", "", "transaction hash (required)")
	rpcURL := flag.String("rpc", "http://localhost:8545", "JSON-RPC endpoint URL")
	caStr := flag.String("ca", "", "BuilderCodes registry contract address (for Schema 0 lookup)")
	flag.Parse()

	if *txHash == "" {
		fmt.Fprintln(os.Stderr, "error: -txhash is required")
		flag.Usage()
		os.Exit(1)
	}

	ctx := context.Background()

	calldata, err := erc8021.FetchCalldata(ctx, *rpcURL, *txHash)
	if err != nil {
		fatalf("fetching calldata: %v", err)
	}

	if !erc8021.HasMarker(calldata) {
		fmt.Println("No ERC-8021 marker found in this transaction.")
		os.Exit(0)
	}

	data, err := erc8021.Parse(calldata)
	if err != nil {
		fatalf("parsing ERC-8021 data: %v", err)
	}

	fmt.Printf("TxData: %s\n\n", data.TxDataHex())
	fmt.Println("── Attribution ──────────────────────────────────────────")

	switch data.Attribution.SchemaID {

	case erc8021.SchemaCanonicalV0:
		s0, err := data.Attribution.DecodeSchema0()
		if err != nil {
			fatalf("decoding Schema 0: %v", err)
		}
		fmt.Println(s0)

		// Schema 0: registry address comes from the -ca flag (host chain).
		if *caStr == "" {
			fmt.Println("\n(pass -ca <address> to query the BuilderCodes registry)")
			return
		}
		registryAddr, err := parseAddr(*caStr)
		if err != nil {
			fatalf("invalid -ca address %q: %v", *caStr, err)
		}
		printRegistryResults(ctx, *rpcURL, registryAddr, s0.Codes, "")

	case erc8021.SchemaCanonicalV1:
		s1, err := data.Attribution.DecodeSchema1()
		if err != nil {
			fatalf("decoding Schema 1: %v", err)
		}
		fmt.Println(s1)

		// Schema 1: registry address is embedded in the calldata; -ca is ignored.
		registryAddr := s1.RegistryAddress
		chainNote := fmt.Sprintf("chain 0x%s", hex.EncodeToString(s1.RegistryChainID))
		printRegistryResults(ctx, *rpcURL, registryAddr, s1.Codes, chainNote)

	default:
		fmt.Printf("SchemaID: 0x%02x (unknown)\n", data.Attribution.SchemaID)
		fmt.Printf("Payload:  %s\n", data.Attribution.PayloadHex())
	}
}

// printRegistryResults queries the BuilderCodes registry and prints per-code info.
// chainNote is an optional label (e.g. "chain 0x0a") shown in the section header.
func printRegistryResults(ctx context.Context, rpcURL string, registryAddr [20]byte, codes []string, chainNote string) {
	if len(codes) == 0 {
		return
	}

	addrHex := "0x" + hex.EncodeToString(registryAddr[:])
	header := fmt.Sprintf("\n── Registry: %s", addrHex)
	if chainNote != "" {
		header += " (" + chainNote + ")"
	}
	header += " ────────────────────────"
	fmt.Println(header)

	infos, err := erc8021.QueryRegistry(ctx, rpcURL, registryAddr, codes)
	if err != nil {
		fmt.Fprintf(os.Stderr, "registry query error: %v\n", err)
		return
	}

	for _, info := range infos {
		fmt.Printf("\n  Code:          %s\n", info.Code)
		fmt.Printf("  IsRegistered:  %v\n", info.IsRegistered)
		if info.IsRegistered {
			fmt.Printf("  Owner:         %s\n", info.Owner.Hex())
			fmt.Printf("  PayoutAddress: %s\n", info.PayoutAddress.Hex())
			fmt.Printf("  CodeURI:       %s\n", info.CodeURI)
		}
	}
}

// parseAddr parses a hex Ethereum address (with or without 0x prefix) into [20]byte.
func parseAddr(s string) ([20]byte, error) {
	s = strings.TrimPrefix(s, "0x")
	s = strings.TrimPrefix(s, "0X")
	b, err := hex.DecodeString(s)
	if err != nil {
		return [20]byte{}, err
	}
	if len(b) != 20 {
		return [20]byte{}, fmt.Errorf("expected 20 bytes, got %d", len(b))
	}
	var addr [20]byte
	copy(addr[:], b)
	return addr, nil
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "error: "+format+"\n", args...)
	os.Exit(1)
}
