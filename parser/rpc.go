package erc8021

import (
	"context"
	"fmt"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/ethclient"
)

// FetchCalldata retrieves the input (calldata) of a transaction identified by
// txHash from an Ethereum-compatible JSON-RPC endpoint at rpcURL.
//
// It dials the endpoint via go-ethereum's ethclient, calls
// TransactionByHash, and returns tx.Data().
// Returns an error if the transaction is not found or the RPC call fails.
func FetchCalldata(ctx context.Context, rpcURL, txHash string) ([]byte, error) {
	client, err := ethclient.DialContext(ctx, rpcURL)
	if err != nil {
		return nil, fmt.Errorf("erc8021/rpc: dial %s: %w", rpcURL, err)
	}
	defer client.Close()

	tx, _, err := client.TransactionByHash(ctx, common.HexToHash(txHash))
	if err != nil {
		return nil, fmt.Errorf("erc8021/rpc: TransactionByHash %s: %w", txHash, err)
	}
	return tx.Data(), nil
}

// FetchAndParseCallData is a convenience wrapper that fetches the calldata for txHash
// from rpcURL and immediately parses it as ERC-8021.
func FetchAndParseCallData(ctx context.Context, rpcURL, txHash string) (*Data, error) {
	calldata, err := FetchCalldata(ctx, rpcURL, txHash)
	if err != nil {
		return nil, err
	}
	return Parse(calldata)
}
