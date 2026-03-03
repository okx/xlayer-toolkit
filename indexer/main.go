// Command erc8021 fetches a transaction by hash and prints its ERC-8021
// attribution data.
//
// Usage:
//
//	erc8021 -txhash <0x…> [-rpc <url>]
package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	erc8021 "erc8021"
)

func main() {
	txHash := flag.String("txhash", "", "transaction hash (required)")
	rpcURL := flag.String("rpc", "http://localhost:8545", "JSON-RPC endpoint URL")
	flag.Parse()

	if *txHash == "" {
		fmt.Fprintln(os.Stderr, "error: -txhash is required")
		flag.Usage()
		os.Exit(1)
	}

	ctx := context.Background()

	calldata, err := erc8021.FetchCalldata(ctx, *rpcURL, *txHash)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error fetching calldata: %v\n", err)
		os.Exit(1)
	}

	if !erc8021.HasMarker(calldata) {
		fmt.Println("No ERC-8021 marker found in this transaction.")
		os.Exit(0)
	}

	data, err := erc8021.Parse(calldata)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error parsing ERC-8021 data: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("TxData: %s\n\n", data.TxDataHex())
	fmt.Println("── Attribution ──────────────────────────────")
	printAttribution(data.Attribution)
}

func printAttribution(a erc8021.Attribution) {
	switch a.SchemaID {
	case erc8021.SchemaCanonicalV0:
		s0, err := a.DecodeSchema0()
		if err != nil {
			fmt.Fprintf(os.Stderr, "error decoding Schema 0: %v\n", err)
			os.Exit(1)
		}
		fmt.Println(s0)

	case erc8021.SchemaCanonicalV1:
		s1, err := a.DecodeSchema1()
		if err != nil {
			fmt.Fprintf(os.Stderr, "error decoding Schema 1: %v\n", err)
			os.Exit(1)
		}
		fmt.Println(s1)

	default:
		fmt.Printf("SchemaID: 0x%02x (unknown)\n", a.SchemaID)
		fmt.Printf("Payload:  %s\n", a.PayloadHex())
	}
}
