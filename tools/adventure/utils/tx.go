package utils

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"math"
	"math/big"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	ethcmn "github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
)

type TxParam struct {
	to       ethcmn.Address
	amount   *big.Int
	gasLimit uint64
	gasPrice *big.Int
	data     []byte
}

var (
	// Cached chainId - shared across all nodes
	cachedChainId *big.Int
	chainIdOnce   sync.Once

	// TxHash writer for saving transaction hashes
	txHashChannel chan string
	txHashWriter  *os.File
	writerWg      sync.WaitGroup
)

// getCachedChainId returns cached chainId - only queries once
func getCachedChainId(ethClient *EthClient) (*big.Int, error) {
	var err error
	chainIdOnce.Do(func() {
		cachedChainId, err = ethClient.ChainID(context.Background())
	})
	return cachedChainId, err
}

// ========================================
// TxHash Writer - Async Channel-based
// ========================================

// initTxHashWriter initializes the async tx hash writer
func initTxHashWriter() error {
	if !TransferCfg.SaveTxHashes {
		return nil
	}

	// Create channel with buffer
	txHashChannel = make(chan string, 10000)

	// Fixed output file: txhashes.log in current directory
	outputFile := "./txhashes.log"

	// Open output file (truncate if exists, create if not)
	var err error
	txHashWriter, err = os.OpenFile(
		outputFile,
		os.O_CREATE|os.O_TRUNC|os.O_WRONLY,
		0644,
	)
	if err != nil {
		return fmt.Errorf("failed to open tx hash file: %w", err)
	}

	log.Printf("📝 TxHash writer enabled: %s\n", outputFile)

	// Start async writer goroutine
	writerWg.Add(1)
	go func() {
		defer writerWg.Done()
		for hash := range txHashChannel {
			if _, err := txHashWriter.WriteString(hash + "\n"); err != nil {
				log.Printf("⚠️  Failed to write tx hash: %v\n", err)
			}
		}
	}()

	return nil
}

// writeTxHashAsync writes a tx hash asynchronously (non-blocking)
func writeTxHashAsync(hash string) {
	if !TransferCfg.SaveTxHashes || txHashChannel == nil {
		return
	}

	select {
	case txHashChannel <- hash:
		// Successfully sent to channel
	default:
		// Channel is full, drop the hash (with warning)
		log.Printf("⚠️  TxHash channel full, dropping hash: %s\n", hash)
	}
}

// closeTxHashWriter gracefully closes the tx hash writer
func closeTxHashWriter() {
	if txHashChannel != nil {
		close(txHashChannel)
		writerWg.Wait()
	}
	if txHashWriter != nil {
		if err := txHashWriter.Close(); err != nil {
			log.Printf("⚠️  Failed to close tx hash file: %v\n", err)
		} else {
			log.Printf("✅ TxHash writer closed\n")
		}
	}
}

// Default GasPrice for X1 is set to 10GWei/gas
func ParseGasPriceToBigInt(gasPriceFloat float64, prec int) *big.Int {
	mul, err := strconv.ParseFloat(fmt.Sprintf(`1%0`+strconv.Itoa(prec)+`s`, ""), 64)
	if err != nil {
		return new(big.Int).SetUint64(10000000000)
	}
	gasPriceWeiFloat := gasPriceFloat * mul
	if hasDecimal(gasPriceWeiFloat) {
		return new(big.Int).SetUint64(10000000000)
	}
	return new(big.Int).SetUint64(uint64(gasPriceWeiFloat))
}

func hasDecimal(num float64) bool {
	intPart := math.Floor(num)
	return intPart != num
}

func NewTxParam(to ethcmn.Address, amount *big.Int, gasLimit uint64, gasPrice *big.Int, data []byte) TxParam {
	return TxParam{
		to,
		amount,
		gasLimit,
		gasPrice,
		data,
	}
}

func RunTxs(e func(ethcmn.Address) []TxParam) {
	// Initialize tx hash writer if enabled
	if err := initTxHashWriter(); err != nil {
		log.Printf("⚠️  Failed to initialize tx hash writer: %v\n", err)
	}
	defer closeTxHashWriter()

	clients := GenerateClients(TransferCfg.Rpc)                 // generate CosmosClient or EthClient
	accounts := generateAccounts(TransferCfg.BenchmarkAccounts) // generate 20k benchmark accounts
	mempoolSizeMap := &sync.Map{}
	mempoolSizeMap.Store(0, 0)

	go func() {
		for {
			size := getMempoolSizeV2(TransferCfg.Rpc[0])
			mempoolSizeMap.Store(0, size)
			time.Sleep(time.Second)
		}
	}()

	tpsman := NewTPSMan(TransferCfg.Rpc[0])

	concurrency := TransferCfg.Concurrency
	count := len(accounts) / concurrency
	for i := 0; i < concurrency; i++ {
		go func(gIndex int) {
			for {
				mempoolSize, ok := mempoolSizeMap.Load(0)
				//fmt.Printf("Mempool size: %d\n", mempoolSize)
				if ok && mempoolSize.(int) >= TransferCfg.MempoolPauseThreshold {
					time.Sleep(time.Second * 1)
					continue
				}

				start := gIndex * count
				end := start + count
				if end > len(accounts) {
					end = len(accounts)
				}
				batchAccounts := accounts[start:end]

				// Use batch execution
				cli := clients[gIndex%len(clients)]
				executeBatch(gIndex, cli, batchAccounts, e)
			}
		}(i)
	}

	go tpsman.TPSDisplay()
	select {}
}

var defaultGasPrice = big.NewInt(100000000000)

// Global HTTP client for connection reuse
var httpClient = &http.Client{
	Timeout: 10 * time.Second,
	Transport: &http.Transport{
		MaxIdleConns:          300,              // Increase global max idle connections
		MaxIdleConnsPerHost:   300,              // Increase max idle connections per host
		MaxConnsPerHost:       300,              // Limit max connections per host
		IdleConnTimeout:       90 * time.Second, // Idle connection timeout
		TLSHandshakeTimeout:   10 * time.Second, // TLS handshake timeout
		ExpectContinueTimeout: 1 * time.Second,  // Expect: 100-continue timeout
		DisableKeepAlives:     false,            // Enable Keep-Alive (default is false, explicitly set)
		DisableCompression:    false,            // Enable compression
		ForceAttemptHTTP2:     false,            // For RPC calls, HTTP/1.1 is sufficient
	},
}

type TxPoolStatus struct {
	BaseFee string `json:"baseFee"`
	Pending string `json:"pending"`
	Queued  string `json:"queued"`
}

type TxPoolResponse struct {
	JsonRPC string       `json:"jsonrpc"`
	ID      int          `json:"id"`
	Result  TxPoolStatus `json:"result"`
}

// getMempoolSizeV2 queries mempool size using txpool_status interface
func getMempoolSizeV2(rpcURL string) int {
	// Construct JSON-RPC request
	requestBody := map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "txpool_status",
		"params":  []interface{}{},
		"id":      1,
	}

	jsonData, err := json.Marshal(requestBody)
	if err != nil {
		log.Printf("Failed to marshal request: %v\n", err)
		return 0
	}

	// Send request using reused HTTP client
	resp, err := httpClient.Post(rpcURL, "application/json", bytes.NewBuffer(jsonData))
	if err != nil {
		log.Printf("Failed to send request: %v\n", err)
		return 0
	}
	defer resp.Body.Close()

	// Read response
	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		log.Printf("Failed to read response: %v\n", err)
		return 0
	}

	// Parse response
	var response TxPoolResponse
	err = json.Unmarshal(body, &response)
	if err != nil {
		log.Printf("Failed to unmarshal response: %v\n", err)
		return 0
	}

	// Parse hex strings and calculate total
	baseFee := hexToInt(response.Result.BaseFee)
	pending := hexToInt(response.Result.Pending)
	queued := hexToInt(response.Result.Queued)

	return baseFee + pending + queued
}

func hexToInt(hexStr string) int {
	if hexStr == "" || hexStr == "0x" {
		return 0
	}

	// Remove 0x prefix
	hexStr = strings.TrimPrefix(hexStr, "0x")

	// Parse hexadecimal
	val, err := strconv.ParseInt(hexStr, 16, 64)
	if err != nil {
		log.Printf("Failed to parse hex string %s: %v\n", hexStr, err)
		return 0
	}

	return int(val)
}

// executeBatch executes transactions for multiple accounts in batch
func executeBatch(gIndex int, cli Client, accounts []*EthAccount, e func(ethcmn.Address) []TxParam) {
	const maxBatchSize = 100

	// Check if batch sending is supported
	ethClient, ok := cli.(*EthClient)
	if !ok {
		panic("eth client is not a eth client")
	}

	// Get transaction parameter template (use first transaction from first account as template)
	if len(accounts) == 0 {
		return
	}

	eParams := e(accounts[0].caller)
	txTemplate := eParams[0] // Always only 1, all transactions use the same parameters

	// Calculate total transactions
	totalTxs := len(accounts)

	// Send in batches, max 100 per batch
	for i := 0; i < totalTxs; i += maxBatchSize {
		end := i + maxBatchSize
		if end > totalTxs {
			end = totalTxs
		}

		startAccountIndex := i
		endAccountIndex := end
		if endAccountIndex > len(accounts) {
			endAccountIndex = len(accounts)
		}

		sendSimpleBatch(gIndex, ethClient, txTemplate, accounts[startAccountIndex:endAccountIndex])

		time.Sleep(time.Millisecond * 50)
	}
}

func sendSimpleBatch(gIndex int, ethClient *EthClient, txTemplate TxParam, accounts []*EthAccount) {
	if len(accounts) == 0 {
		return
	}

	// Build and sign all transactions
	var signedTxs []*types.Transaction
	chainId, err := getCachedChainId(ethClient)
	if err != nil {
		log.Printf("[g%d] failed to get chainId: %v\n", gIndex, err)
		return
	}
	signer := types.NewLondonSigner(chainId)

	for _, acc := range accounts {
		acc.Lock()
		if err := acc.SetNonce(ethClient); err != nil {
			log.Printf("[g%d] failed to query nonce: %s\n", gIndex, err)
			acc.Unlock()
			continue
		}

		// Create transaction
		// Use gasPrice from txTemplate if set, otherwise fallback to defaultGasPrice
		gasPrice := defaultGasPrice
		if txTemplate.gasPrice != nil && txTemplate.gasPrice.Cmp(big.NewInt(0)) > 0 {
			gasPrice = txTemplate.gasPrice
		}
		unsignedTx := types.NewTransaction(
			acc.GetNonce(),
			txTemplate.to,
			txTemplate.amount,
			txTemplate.gasLimit,
			gasPrice,
			txTemplate.data,
		)

		// Sign transaction
		signedTx, err := types.SignTx(unsignedTx, signer, acc.GetPrivateKey())
		if err != nil {
			log.Printf("[g%d] failed to sign tx: %v\n", gIndex, err)
			acc.Unlock()
			continue
		}

		signedTxs = append(signedTxs, signedTx)
		acc.Unlock()
	}

	if len(signedTxs) == 0 {
		return
	}

	// Use batch send interface
	txHashes, err := ethClient.SendMultipleEthereumTx(signedTxs)
	if err != nil {
		log.Printf("[g%d] batch send failed: %v\n", gIndex, err)
		if strings.Contains(err.Error(), "Transaction already exists") ||
			strings.Contains(err.Error(), "already known") {
			// Transaction with same hash already in mempool - increment nonce to move forward
			noncePlus1(accounts)
		} else if strings.Contains(err.Error(), "nonce too low") {
			queryNonce(ethClient, accounts)
		}
		return
	}

	// Count successful transactions and update nonce
	successCount := 0
	for i, txHash := range txHashes {
		if txHash != (ethcmn.Hash{}) {
			// Send successful, update corresponding account's nonce
			accounts[i].AddNonce()
			successCount++
			// Write tx hash asynchronously if enabled
			writeTxHashAsync(txHash.Hex())
		}
	}

	if successCount != len(signedTxs) {
		log.Printf("[g%d] batch sent %d/%d transactions successfully\n", gIndex, successCount, len(signedTxs))
	}
}

func noncePlus1(accounts []*EthAccount) {
	for _, acc := range accounts {
		acc.AddNonce()
	}
}

func queryNonce(ethClient *EthClient, accounts []*EthAccount) {
	for _, acc := range accounts {
		acc.queried = false
		_ = acc.SetNonce(ethClient)
	}
}
