package utils

import (
	"context"
	"crypto/ecdsa"
	"fmt"
	"math/big"
	"net/http"
	"time"

	ethcmn "github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/rpc"
)

var (
	_ Client = (*EthClient)(nil)
)

// Client defines the interface for blockchain clients
type Client interface {
	QueryNonce(hexAddr string) (uint64, error)
	SendEthereumTx(privatekey *ecdsa.PrivateKey, nonce uint64, to ethcmn.Address, amount *big.Int, gasLimit uint64, gasPrice *big.Int, data []byte) (ethcmn.Hash, error)
	CreateContract(privatekey *ecdsa.PrivateKey, nonce uint64, amount *big.Int, gasLimit uint64, gasPrice *big.Int, data []byte) (ethcmn.Hash, error)
	SendMultipleEthereumTx(signedTxs []*types.Transaction) ([]ethcmn.Hash, error)
	CodeAt(ctx context.Context, contract ethcmn.Address, blockNumber *big.Int) ([]byte, error)
}

// EthClient wraps the ethereum client with additional functionality
type EthClient struct {
	*ethclient.Client
	rpcClient *rpc.Client
	signer    types.Signer
}

// createOptimizedHTTPClient creates an HTTP client optimized for connection pooling
func createOptimizedHTTPClient() *http.Client {
	transport := &http.Transport{
		MaxIdleConns:        300,              // Increase max idle connections
		MaxIdleConnsPerHost: 300,              // Increase max idle connections per host
		IdleConnTimeout:     30 * time.Second, // Extend idle connection timeout
		DisableKeepAlives:   false,            // Enable keep-alive (critical optimization)
		MaxConnsPerHost:     300,              // Limit max connections per host
	}

	return &http.Client{
		Transport: transport,
		Timeout:   10 * time.Second, // Request timeout
	}
}

// NewEthClient creates a new Ethereum client with optimized settings
func NewEthClient(ip string) (*EthClient, error) {
	// Create RPC client with optimized HTTP client
	httpClient := createOptimizedHTTPClient()
	rpcClient, err := rpc.DialOptions(context.Background(), ip, rpc.WithHTTPClient(httpClient))
	if err != nil {
		return nil, fmt.Errorf("failed to initialize rpc client: %+v", err)
	}

	// Create Ethereum client based on RPC client
	cli := ethclient.NewClient(rpcClient)

	chainId, err := cli.ChainID(context.Background())
	if err != nil {
		return nil, err
	}

	return &EthClient{
		cli,
		rpcClient,
		types.NewLondonSigner(chainId),
	}, nil
}

// QueryNonce queries the pending nonce for the given address
func (e EthClient) QueryNonce(hexAddr string) (uint64, error) {
	nonce, err := e.PendingNonceAt(context.Background(), ethcmn.HexToAddress(hexAddr))
	if err != nil {
		return 0, err
	}
	return nonce, nil
}

// QueryAANonce queries the EIP-8130 2D nonce sequence for address/nonceKey.
func (e EthClient) QueryAANonce(addr ethcmn.Address, nonceKey *big.Int) (uint64, error) {
	var result string
	err := e.rpcClient.CallContext(
		context.Background(),
		&result,
		"eth_getTransactionCount",
		addr,
		"pending",
		hexutil.EncodeBig(nonceKey),
	)
	if err != nil {
		return 0, err
	}

	value, err := hexutil.DecodeBig(result)
	if err != nil {
		return 0, err
	}
	if !value.IsUint64() {
		return 0, fmt.Errorf("AA nonce overflows uint64: %s", result)
	}
	return value.Uint64(), nil
}

// BatchAANonces queries pending EIP-8130 nonce sequences for one nonce key.
func (e EthClient) BatchAANonces(ctx context.Context, addrs []ethcmn.Address, nonceKey *big.Int) ([]uint64, error) {
	if len(addrs) == 0 {
		return nil, nil
	}

	batch := make([]rpc.BatchElem, len(addrs))
	results := make([]string, len(addrs))
	encodedNonceKey := hexutil.EncodeBig(nonceKey)
	for i, addr := range addrs {
		batch[i] = rpc.BatchElem{
			Method: "eth_getTransactionCount",
			Args:   []interface{}{addr, "pending", encodedNonceKey},
			Result: &results[i],
		}
	}

	if err := e.rpcClient.BatchCallContext(ctx, batch); err != nil {
		return nil, fmt.Errorf("AA nonce batch call failed: %w", err)
	}

	sequences := make([]uint64, len(addrs))
	var errors []string
	for i, elem := range batch {
		if elem.Error != nil {
			errors = append(errors, fmt.Sprintf("account %d %s: %v", i, addrs[i], elem.Error))
			continue
		}
		value, err := hexutil.DecodeBig(results[i])
		if err != nil {
			errors = append(errors, fmt.Sprintf("account %d %s: decode nonce %q: %v", i, addrs[i], results[i], err))
			continue
		}
		if !value.IsUint64() {
			errors = append(errors, fmt.Sprintf("account %d %s: AA nonce overflows uint64: %s", i, addrs[i], results[i]))
			continue
		}
		sequences[i] = value.Uint64()
	}
	if len(errors) > 0 {
		return sequences, fmt.Errorf("AA nonce batch errors: %v", errors)
	}

	return sequences, nil
}

// BatchBalances queries latest balances for multiple addresses in one RPC batch.
func (e EthClient) BatchBalances(ctx context.Context, addrs []ethcmn.Address) ([]*big.Int, error) {
	if len(addrs) == 0 {
		return nil, nil
	}

	batch := make([]rpc.BatchElem, len(addrs))
	results := make([]hexutil.Big, len(addrs))
	for i, addr := range addrs {
		batch[i] = rpc.BatchElem{
			Method: "eth_getBalance",
			Args:   []interface{}{addr, "latest"},
			Result: &results[i],
		}
	}

	if err := e.rpcClient.BatchCallContext(ctx, batch); err != nil {
		return nil, fmt.Errorf("balance batch call failed: %w", err)
	}

	balances := make([]*big.Int, len(addrs))
	var errors []string
	for i, elem := range batch {
		if elem.Error != nil {
			errors = append(errors, fmt.Sprintf("account %d %s: %v", i, addrs[i], elem.Error))
			balances[i] = big.NewInt(0)
			continue
		}
		balances[i] = new(big.Int).Set((*big.Int)(&results[i]))
	}
	if len(errors) > 0 {
		return balances, fmt.Errorf("balance batch errors: %v", errors)
	}

	return balances, nil
}

// SendEthereumTx signs and sends an Ethereum transaction
func (e EthClient) SendEthereumTx(privatekey *ecdsa.PrivateKey, nonce uint64, to ethcmn.Address, amount *big.Int, gasLimit uint64, gasPrice *big.Int, data []byte) (ethcmn.Hash, error) {
	// 1. Create transaction
	unsignedTx := types.NewTransaction(nonce, to, amount, gasLimit, gasPrice, data)

	// 2. Sign transaction
	signedTx, err := types.SignTx(unsignedTx, e.signer, privatekey)
	if err != nil {
		return ethcmn.Hash{}, err
	}

	// 3. Send transaction
	err = e.SendTransaction(context.Background(), signedTx)
	// debug
	// println("tx hash:", signedTx.Hash().Hex())
	if err != nil {
		return ethcmn.Hash{}, err
	}

	return signedTx.Hash(), err
}

// CreateContract creates a contract by sending a contract creation transaction
func (e EthClient) CreateContract(privatekey *ecdsa.PrivateKey, nonce uint64, amount *big.Int, gasLimit uint64, gasPrice *big.Int, data []byte) (ethcmn.Hash, error) {
	// 1. Create contract creation transaction
	unsignedTx := types.NewContractCreation(nonce, amount, gasLimit, gasPrice, data)

	// 2. Sign transaction
	signedTx, err := types.SignTx(unsignedTx, e.signer, privatekey)
	if err != nil {
		return ethcmn.Hash{}, err
	}

	// 3. Send transaction
	err = e.SendTransaction(context.Background(), signedTx)
	if err != nil {
		return ethcmn.Hash{}, err
	}

	return signedTx.Hash(), err
}

// SendMultipleEthereumTx sends multiple signed transactions in a single batch RPC call
func (e EthClient) SendMultipleEthereumTx(signedTxs []*types.Transaction) ([]ethcmn.Hash, error) {
	if len(signedTxs) == 0 {
		return nil, fmt.Errorf("empty transaction list")
	}

	// Prepare batch RPC request
	batch := make([]rpc.BatchElem, len(signedTxs))
	txHashes := make([]string, len(signedTxs))

	for i, signedTx := range signedTxs {
		// Encode transaction to hex string
		//println("tx hash:", signedTx.Hash().Hex())
		txData, err := signedTx.MarshalBinary()
		if err != nil {
			return nil, fmt.Errorf("failed to marshal tx %d: %v", i, err)
		}
		txHex := "0x" + fmt.Sprintf("%x", txData)

		// Prepare batch RPC call element
		batch[i] = rpc.BatchElem{
			Method: "eth_sendRawTransaction",
			Args:   []interface{}{txHex},
			Result: &txHashes[i],
		}
	}

	// Execute batch RPC call - only one HTTP request!
	err := e.rpcClient.BatchCall(batch)
	if err != nil {
		return nil, fmt.Errorf("batch call failed: %v", err)
	}

	//time.Sleep(10 * time.Second) // Simulate processing time
	//log.Fatal("debug batch call completed, processing results...")
	// Process results
	var resultHashes []ethcmn.Hash
	var errors []string

	for i, elem := range batch {
		if elem.Error != nil {
			errors = append(errors, fmt.Sprintf("tx %d: %v", i, elem.Error))
			resultHashes = append(resultHashes, ethcmn.Hash{})
		} else {
			// Convert string to Hash
			if txHashes[i] != "" {
				resultHashes = append(resultHashes, ethcmn.HexToHash(txHashes[i]))
			} else {
				resultHashes = append(resultHashes, ethcmn.Hash{})
			}
		}
	}

	if len(errors) > 0 {
		return resultHashes, fmt.Errorf("batch errors: %v", errors)
	}

	return resultHashes, nil
}

// SendMultipleRawTransactions sends already-encoded raw transactions in a batch RPC call.
func (e EthClient) SendMultipleRawTransactions(rawTxs []string) ([]ethcmn.Hash, error) {
	if len(rawTxs) == 0 {
		return nil, fmt.Errorf("empty transaction list")
	}

	batch := make([]rpc.BatchElem, len(rawTxs))
	txHashes := make([]string, len(rawTxs))
	for i, rawTx := range rawTxs {
		batch[i] = rpc.BatchElem{
			Method: "eth_sendRawTransaction",
			Args:   []interface{}{rawTx},
			Result: &txHashes[i],
		}
	}

	if err := e.rpcClient.BatchCall(batch); err != nil {
		return nil, fmt.Errorf("batch call failed: %v", err)
	}

	resultHashes := make([]ethcmn.Hash, 0, len(rawTxs))
	var errors []string
	for i, elem := range batch {
		if elem.Error != nil {
			errors = append(errors, fmt.Sprintf("tx %d: %v", i, elem.Error))
			resultHashes = append(resultHashes, ethcmn.Hash{})
			continue
		}
		if txHashes[i] == "" {
			resultHashes = append(resultHashes, ethcmn.Hash{})
			continue
		}
		resultHashes = append(resultHashes, ethcmn.HexToHash(txHashes[i]))
	}
	if len(errors) > 0 {
		return resultHashes, fmt.Errorf("batch errors: %v", errors)
	}

	return resultHashes, nil
}

// NewClient creates a new client for the given IP
func NewClient(ip string) Client {
	ethClient, err := NewEthClient(ip)
	if err != nil {
		panic(err)
	}
	return ethClient
}

// GenerateClients creates multiple clients for the given IPs
func GenerateClients(ips []string) (clients []Client) {
	for _, ip := range ips {
		clients = append(clients, NewClient(ip))
	}
	return
}
