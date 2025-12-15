package utils

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"time"

	"github.com/ethereum/go-ethereum/core/types"

	"github.com/ethereum/go-ethereum/ethclient"
)

type SimpleTPSManager struct {
	ethclient.Client
	// time recorder for average TPS
	aveStartTime time.Time
	// time recorder for instant TPS
	insStartTime time.Time
	// save start BlockNum for average TPS
	startBlockNum uint64
	// save last BlockNum query for instant TPS
	lastBlockNum uint64
	maxTPS       float64
	minTPS       float64

	url string
}

func NewTPSMan(clientURL string) *SimpleTPSManager {
	//Dial EthClient
	client, err := ethclient.Dial(clientURL)
	if err != nil {
		panic(fmt.Errorf("failed to initialize tps query client: %+v", err))
	}

	return &SimpleTPSManager{
		Client:        *client,
		aveStartTime:  time.Now(),
		insStartTime:  time.Now(),
		startBlockNum: 0,
		lastBlockNum:  0,
		maxTPS:        -1,
		minTPS:        1000000,
		url:           clientURL,
	}
}

func (tpsman *SimpleTPSManager) GetBlockNum() uint64 {
	var blockCount uint64
	var err error

	for {
		blockCount, err = tpsman.BlockNumber(context.Background())
		if err != nil {
			time.Sleep(200 * time.Millisecond)
		} else {
			break
		}
	}
	return blockCount
}

func (tpsman *SimpleTPSManager) BlockHeder(height uint64) *types.Header {
	for {
		header, err := tpsman.HeaderByNumber(context.Background(), big.NewInt(int64(height)))
		if err != nil {
			time.Sleep(time.Millisecond * 200)
		} else {
			return header
		}
	}
}

func (tpsman *SimpleTPSManager) TPSDisplay() {
	time.Sleep(time.Second * 10)
	fmt.Println("TPSDisplay")
	var initHeight uint64
	var totalTxCount uint64
	var initTime time.Time
	for {
		height := tpsman.GetBlockNum()
		txCount, err := tpsman.transactionCountByHeight(height)
		if err != nil {
			panic(err)
		}
		// skip this block
		if txCount > 0 {
			initHeight = height
			initTime = time.Now()
			break
		} else {
			fmt.Println("height", height, "txcount", txCount)
			time.Sleep(time.Millisecond * 200)
		}
	}
	fmt.Println("initHeight", initHeight)
	lastHeight := initHeight
	
	// Track interval-based metrics
	var intervalStartTime time.Time = initTime
	var intervalTxCount uint64 = 0
	var intervalStartHeight uint64 = initHeight
	
	// Track overall metrics
	var avgTPS float64
	var maxTps float64
	var minTps float64 = 100000
	
	for {
		newblockNum := tpsman.GetBlockNum()
		// No tx is executed
		if lastHeight == newblockNum {
			time.Sleep(1 * time.Second)
			continue
		}

		// Process new blocks
		for height := lastHeight + 1; height <= newblockNum; height++ {
			txCount, err := tpsman.transactionCountByHeight(height)
			if err != nil {
				panic(err)
			}
			totalTxCount += txCount
			intervalTxCount += txCount
			lastHeight = height
		}
		
		// Calculate interval TPS (actual on-chain throughput for this interval)
		intervalDuration := time.Since(intervalStartTime).Seconds()
		var instantTPS float64
		if intervalDuration > 0 {
			instantTPS = float64(intervalTxCount) / intervalDuration
		}
		
		// Calculate average TPS (overall throughput)
		avgTPS = float64(totalTxCount) / float64(time.Since(initTime).Seconds())
		
		// Update min/max based on interval TPS (not average)
		if instantTPS > maxTps {
			maxTps = instantTPS
		}
		if intervalTxCount > 0 && instantTPS < minTps {
			minTps = instantTPS
		}
		
		// Calculate blocks per interval
		blocksInInterval := lastHeight - intervalStartHeight
		
		fmt.Println("========================================================")
		fmt.Printf("[TPS log] StartBlock: %d, EndBlock: %d, Blocks: %d, TxsInInterval: %d\n", 
			intervalStartHeight+1, lastHeight, blocksInInterval, intervalTxCount)
		fmt.Printf("[Interval] Instant TPS: %5.2f (over last %.1fs)\n", instantTPS, intervalDuration)
		fmt.Printf("[Overall] Avg TPS: %5.2f, Max TPS: %5.2f, Min TPS: %5.2f, Total Txs: %d, Duration: %ds\n", 
			avgTPS, maxTps, minTps, totalTxCount, int64(time.Since(initTime).Seconds()))
		fmt.Println("========================================================")

		// Reset interval counters
		intervalStartTime = time.Now()
		intervalTxCount = 0
		intervalStartHeight = lastHeight
		
		time.Sleep(5 * time.Second)
	}

}

func (tpsman *SimpleTPSManager) transactionCountByHeight(height uint64) (uint64, error) {
	// Construct JSON-RPC request
	requestBody := map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "eth_getBlockByNumber",
		"params":  []interface{}{fmt.Sprintf("0x%x", height), false}, // false means don't return full transaction details
		"id":      1,
	}

	jsonData, err := json.Marshal(requestBody)
	if err != nil {
		return 0, fmt.Errorf("error marshaling JSON request: %v", err)
	}

	// Send HTTP request
	resp, err := http.Post(tpsman.url, "application/json", bytes.NewBuffer(jsonData))
	if err != nil {
		return 0, fmt.Errorf("error sending HTTP request: %v", err)
	}
	defer resp.Body.Close()

	// Read response
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, fmt.Errorf("error reading response body: %v", err)
	}

	// Parse JSON-RPC response
	var rpcResponse struct {
		Result *struct {
			Transactions []string `json:"transactions"` // When false, this is an array of transaction hashes
		} `json:"result"`
		Error *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}

	if err := json.Unmarshal(body, &rpcResponse); err != nil {
		return 0, fmt.Errorf("error unmarshaling JSON response: %v", err)
	}

	// Check for errors
	if rpcResponse.Error != nil {
		return 0, fmt.Errorf("JSON-RPC error: %s", rpcResponse.Error.Message)
	}

	// Check if result is empty
	if rpcResponse.Result == nil {
		return 0, nil
	}

	// Return transaction count
	return uint64(len(rpcResponse.Result.Transactions)), nil
}
