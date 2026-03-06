package utils

import (
	"bytes"
	"context"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"strconv"
	"sync"
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

var tpsCSVReportFile string

// EnableBenchmarkCSVReport sets the CSV report filename. An empty string disables
// reporting. A non-empty string enables it; if the value equals "-", the default
// timestamped filename is used instead.
func EnableBenchmarkCSVReport(filename string) {
	tpsCSVReportFile = filename
}

type tpsCSVWriter struct {
	mu     sync.Mutex
	closed bool
	path   string
	file   *os.File
	writer *csv.Writer
}

var currentBenchmarkCSVWriter *tpsCSVWriter

func buildBenchmarkCSVReportPath() string {
	ts := time.Now().Format("20060102_150405")
	return fmt.Sprintf("./benchmark_report_%s.csv", ts)
}

func initBenchmarkCSVWriter() (*tpsCSVWriter, error) {
	if tpsCSVReportFile == "" {
		return nil, nil
	}

	reportPath := tpsCSVReportFile
	if reportPath == "-" {
		reportPath = buildBenchmarkCSVReportPath()
	}
	file, err := os.OpenFile(reportPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0644)
	if err != nil {
		return nil, fmt.Errorf("failed to open tps csv file: %w", err)
	}

	writer := csv.NewWriter(file)
	if err := writer.Write([]string{
		"timestamp",
		"start_block_num",
		"new_block_num",
		"total_tx_count",
		"average_btps",
		"max_tps",
		"min_tps",
		"time_last_seconds",
		"cpu_percent",
		"mem_percent",
		"mem_used_bytes",
		"mem_total_bytes",
		"disk_read_bytes_per_sec",
		"disk_write_bytes_per_sec",
	}); err != nil {
		file.Close()
		return nil, fmt.Errorf("failed to write tps csv header: %w", err)
	}
	writer.Flush()
	if err := writer.Error(); err != nil {
		file.Close()
		return nil, fmt.Errorf("failed to flush tps csv header: %w", err)
	}

	log.Printf("📝 TPS CSV report enabled: %s\n", reportPath)
	csvWriter := &tpsCSVWriter{path: reportPath, file: file, writer: writer}
	currentBenchmarkCSVWriter = csvWriter
	return csvWriter, nil
}

func (w *tpsCSVWriter) WriteRecord(startBlockNum, newBlockNum, totalTxCount uint64, avgTPS, maxTPS, minTPS float64, elapsedSeconds int64, sys SysMetrics) error {
	if w == nil {
		return nil
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return nil
	}

	record := []string{
		time.Now().Format(time.RFC3339),
		strconv.FormatUint(startBlockNum, 10),
		strconv.FormatUint(newBlockNum, 10),
		strconv.FormatUint(totalTxCount, 10),
		fmt.Sprintf("%.2f", avgTPS),
		fmt.Sprintf("%.2f", maxTPS),
		fmt.Sprintf("%.2f", minTPS),
		strconv.FormatInt(elapsedSeconds, 10),
		fmt.Sprintf("%.2f", sys.CPUPercent),
		fmt.Sprintf("%.2f", sys.MemPercent),
		strconv.FormatUint(sys.MemUsedBytes, 10),
		strconv.FormatUint(sys.MemTotalBytes, 10),
		fmt.Sprintf("%.0f", sys.DiskReadBytesPerSec),
		fmt.Sprintf("%.0f", sys.DiskWriteBytesPerSec),
	}
	if err := w.writer.Write(record); err != nil {
		return err
	}
	w.writer.Flush()
	return w.writer.Error()
}

func (w *tpsCSVWriter) Close() {
	if w == nil {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return
	}
	w.closed = true
	w.writer.Flush()
	if err := w.writer.Error(); err != nil {
		log.Printf("⚠️  Failed to flush TPS CSV report: %v\n", err)
	}
	if err := w.file.Close(); err != nil {
		log.Printf("⚠️  Failed to close TPS CSV report: %v\n", err)
	}
}

// CloseBenchmarkCSVReport flushes and closes active benchmark CSV report if enabled.
func CloseBenchmarkCSVReport() {
	if currentBenchmarkCSVWriter != nil {
		currentBenchmarkCSVWriter.Close()
		currentBenchmarkCSVWriter = nil
	}
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
	csvWriter, err := initBenchmarkCSVWriter()
	if err != nil {
		log.Printf("⚠️  Failed to initialize TPS CSV report: %v\n", err)
	}
	defer func() {
		if csvWriter != nil {
			CloseBenchmarkCSVReport()
		}
	}()

	sysCollector := NewSysMetricsCollector()

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
			txCount, err := tpsman.transactionCountByHeight(height)
			if err != nil {
				panic(err)
			}
			totalTxCount += txCount
			lastHeight = height

			avgTPS = float64(totalTxCount) / float64(time.Since(initTime).Seconds())
			if avgTPS > maxTps {
				maxTps = avgTPS
			}
			if avgTPS < minTps {
				minTps = avgTPS
			}
		}
		elapsedSeconds := int64(time.Since(initTime).Seconds())

		sys := sysCollector.Sample()

		fmt.Println("========================================================")
		fmt.Printf("[TPS log] StartBlock Num: %d, NewBlockNum: %d, totalTxCount:%d\n", initHeight+1, lastHeight, totalTxCount)
		fmt.Printf("[Summary] Average BTPS: %5.2f, Max TPS: %5.2f, Min TPS: %5.2f, Time Last: %ds\n", avgTPS, maxTps, minTps, elapsedSeconds)
		fmt.Printf("[SysMon]  %s\n", sys.FormatConsole())
		fmt.Println("========================================================")
		if err := csvWriter.WriteRecord(initHeight+1, lastHeight, totalTxCount, avgTPS, maxTps, minTps, elapsedSeconds, sys); err != nil {
			log.Printf("⚠️  Failed to write TPS CSV record: %v\n", err)
		}

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
