// Command erc8021 parses ERC-8021 attribution data.
//
// Subcommands:
//
//	erc8021 parse --input <hex> [-ca <0x…>] [-rpc <url>]
//	    Parse ERC-8021 attribution from a raw hex calldata string.
//
//	erc8021 -txhash <0x…> [-rpc <url>] [-ca <0x…>]
//	    Fetch a transaction by hash and parse its ERC-8021 attribution suffix.
package main

import (
	"context"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"

	erc8021 "erc8021"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "parse" {
		cmdParse(os.Args[2:])
		return
	}
	cmdTx(os.Args[1:])
}

// cmdParse handles: erc8021 parse --input <hex> [-ca <addr>] [-rpc <url>]
func cmdParse(args []string) {
	fs := flag.NewFlagSet("parse", flag.ExitOnError)
	input := fs.String("input", "", "hex-encoded calldata to parse (required)")
	caStr := fs.String("ca", "", "BuilderCodes registry address (Schema 0 lookup)")
	rpcURL := fs.String("rpc", "http://localhost:8545", "JSON-RPC endpoint URL (for registry lookup)")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: erc8021 parse --input <hex> [-ca <0x…>] [-rpc <url>]")
		fs.PrintDefaults()
	}
	_ = fs.Parse(args)

	if *input == "" {
		fmt.Fprintln(os.Stderr, "error: --input is required")
		fs.Usage()
		os.Exit(1)
	}

	data, err := erc8021.ParseHex(*input)
	if err != nil {
		fatalf("parsing calldata: %v", err)
	}

	printAttribution(context.Background(), data, *rpcURL, *caStr)
}

// cmdTx handles: erc8021 -txhash <hash> [-rpc <url>] [-ca <addr>]
func cmdTx(args []string) {
	fs := flag.NewFlagSet("tx", flag.ExitOnError)
	txHash := fs.String("txhash", "", "transaction hash (required)")
	rpcURL := fs.String("rpc", "http://localhost:8545", "JSON-RPC endpoint URL")
	caStr := fs.String("ca", "", "BuilderCodes registry contract address (for Schema 0 lookup)")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: erc8021 -txhash <0x…> [-rpc <url>] [-ca <0x…>]")
		fmt.Fprintln(os.Stderr, "       erc8021 parse --input <hex> [-rpc <url>] [-ca <0x…>]")
		fs.PrintDefaults()
	}
	_ = fs.Parse(args)

	if *txHash == "" {
		fmt.Fprintln(os.Stderr, "error: -txhash is required")
		fs.Usage()
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

	printAttribution(ctx, data, *rpcURL, *caStr)
}

// printAttribution prints parsed ERC-8021 fields and optionally queries the registry.
func printAttribution(ctx context.Context, data *erc8021.Data, rpcURL, caStr string) {
	fmt.Printf("TxData(without attribution): %s\n\n", data.TxDataHex())
	fmt.Println("── Attribution ──────────────────────────────────────────")

	switch data.Attribution.SchemaID {

	case erc8021.SchemaCanonicalV0:
		s0, err := data.Attribution.DecodeSchema0()
		if err != nil {
			fatalf("decoding Schema 0: %v", err)
		}
		fmt.Println(s0)

		if caStr == "" {
			fmt.Println("\n(pass -ca <address> to query the BuilderCodes registry)")
			return
		}
		registryAddr, err := parseAddr(caStr)
		if err != nil {
			fatalf("invalid -ca address %q: %v", caStr, err)
		}
		printRegistryResults(ctx, rpcURL, registryAddr, s0.Codes, "")

	case erc8021.SchemaCanonicalV1:
		s1, err := data.Attribution.DecodeSchema1()
		if err != nil {
			fatalf("decoding Schema 1: %v", err)
		}
		fmt.Println(s1)

		registryAddr := s1.RegistryAddress
		chainNote := fmt.Sprintf("chain 0x%s", hex.EncodeToString(s1.RegistryChainID))
		printRegistryResults(ctx, rpcURL, registryAddr, s1.Codes, chainNote)

	default:
		fmt.Printf("SchemaID: 0x%02x (unknown)\n", data.Attribution.SchemaID)
		fmt.Printf("Payload:  %s\n", data.Attribution.PayloadHex())
	}
}

// printRegistryResults queries the BuilderCodes registry and prints per-code info.
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
		if errors.Is(err, erc8021.ErrNotDeployed) {
			fmt.Fprintf(os.Stderr, "error: registry not deployed at %s (rpc: %s)\n", addrHex, rpcURL)
		} else {
			fmt.Fprintf(os.Stderr, "registry query error: %v\n", err)
		}
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
