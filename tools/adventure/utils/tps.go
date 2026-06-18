package utils

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strings"
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
	var gaslessTxCount uint64
	var paidTxCount uint64
	var initTime time.Time
	for {
		height := tpsman.GetBlockNum()
		bd, err := tpsman.transactionCountByHeight(height)
		if err != nil {
			panic(err)
		}
		// skip this block
		if bd.Total > 0 {
			initHeight = height
			initTime = time.Now()
			break
		} else {
			fmt.Println("height", height, "txcount", bd.Total)
			time.Sleep(time.Millisecond * 200)
			initHeight = height
			initTime = time.Now()
			break
		}
	}
	fmt.Println("initHeight", initHeight)
	lastHeight := initHeight
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

		for height := lastHeight + 1; height <= newblockNum; height++ {
			bd, err := tpsman.transactionCountByHeight(height)
			if err != nil {
				panic(err)
			}
			totalTxCount += bd.Total
			gaslessTxCount += bd.Gasless
			paidTxCount += bd.Paid
			lastHeight = height

			avgTPS = float64(totalTxCount) / float64(time.Since(initTime).Seconds())
			if avgTPS > maxTps {
				maxTps = avgTPS
			}
			if avgTPS < minTps {
				minTps = avgTPS
			}
		}
		elapsed := time.Since(initTime).Seconds()
		gaslessTPS := float64(gaslessTxCount) / elapsed
		paidTPS := float64(paidTxCount) / elapsed
		fmt.Println("========================================================")
		fmt.Printf("[TPS log] StartBlock Num: %d, NewBlockNum: %d, totalTxCount:%d (gasless:%d paid:%d)\n",
			initHeight+1, lastHeight, totalTxCount, gaslessTxCount, paidTxCount)
		fmt.Printf("[Summary] Average BTPS  total: %5.2f, gasless: %5.2f, paid: %5.2f | Max TPS: %5.2f, Min TPS: %5.2f, Time Last: %ds\n",
			avgTPS, gaslessTPS, paidTPS, maxTps, minTps, int64(elapsed))
		fmt.Println("========================================================")

		time.Sleep(5 * time.Second)
	}

}

// txBreakdown splits a block's transactions into the categories the TPS summary reports.
// Total counts every tx; Gasless + Paid + Deposit == Total.
type txBreakdown struct {
	Total   uint64
	Gasless uint64 // zero gas-price, non-deposit (the gasless-whitelisted txs)
	Paid    uint64 // pays gas (effective gas price > 0)
	Deposit uint64 // OP-stack deposit/system txs (type 0x7e), excluded from Gasless
}

// depositTxType is the OP-stack deposit (system) transaction type. These are zero-priced like
// gasless txs but are not user gasless txs, so they are counted separately.
const depositTxType = "0x7e"

// isZeroHexValue reports whether a hex quantity string (e.g. "0x0", "0x", "") represents zero.
func isZeroHexValue(s string) bool {
	s = strings.TrimPrefix(strings.TrimSpace(s), "0x")
	if s == "" {
		return true
	}
	for _, c := range s {
		if c != '0' {
			return false
		}
	}
	return true
}

func (tpsman *SimpleTPSManager) transactionCountByHeight(height uint64) (txBreakdown, error) {
	var bd txBreakdown

	// Construct JSON-RPC request. true => full tx objects, so we can classify each tx by
	// type (deposit) and gas price (gasless vs paid).
	requestBody := map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "eth_getBlockByNumber",
		"params":  []interface{}{fmt.Sprintf("0x%x", height), true},
		"id":      1,
	}

	jsonData, err := json.Marshal(requestBody)
	if err != nil {
		return bd, fmt.Errorf("error marshaling JSON request: %v", err)
	}

	// Send HTTP request
	resp, err := http.Post(tpsman.url, "application/json", bytes.NewBuffer(jsonData))
	if err != nil {
		return bd, fmt.Errorf("error sending HTTP request: %v", err)
	}
	defer resp.Body.Close()

	// Read response
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return bd, fmt.Errorf("error reading response body: %v", err)
	}

	// Parse JSON-RPC response (full tx objects)
	var rpcResponse struct {
		Result *struct {
			Transactions []struct {
				Type     string `json:"type"`
				GasPrice string `json:"gasPrice"`
			} `json:"transactions"`
		} `json:"result"`
		Error *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}

	if err := json.Unmarshal(body, &rpcResponse); err != nil {
		return bd, fmt.Errorf("error unmarshaling JSON response: %v", err)
	}

	// Check for errors
	if rpcResponse.Error != nil {
		return bd, fmt.Errorf("JSON-RPC error: %s", rpcResponse.Error.Message)
	}

	// Check if result is empty
	if rpcResponse.Result == nil {
		return bd, nil
	}

	for _, tx := range rpcResponse.Result.Transactions {
		bd.Total++
		switch {
		case strings.EqualFold(tx.Type, depositTxType):
			bd.Deposit++
		case isZeroHexValue(tx.GasPrice):
			bd.Gasless++
		default:
			bd.Paid++
		}
	}
	return bd, nil
}
