package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

type RPCRequest struct {
	Jsonrpc string        `json:"jsonrpc"`
	Method  string        `json:"method"`
	Params  []interface{} `json:"params"`
	ID      int           `json:"id"`
}

type RPCResponse struct {
	Jsonrpc string `json:"jsonrpc"`
	ID      int    `json:"id"`
	Result  *struct {
		Hash string `json:"hash"`
	} `json:"result"`
	Error *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

type RPCCompare struct {
	url1, url2  string
	client      *http.Client
	startHeight int64
	endHeight   int64
	logger      *log.Logger
}

func NewRPCCompare(url1, url2 string, startHeight, endHeight int64, logger *log.Logger) *RPCCompare {
	return &RPCCompare{
		url1:        url1,
		url2:        url2,
		startHeight: startHeight,
		endHeight:   endHeight,
		client: &http.Client{
			Timeout: 30 * time.Second,
		},
		logger: logger,
	}
}

func (r *RPCCompare) logf(format string, v ...interface{}) {
	if r.logger != nil {
		r.logger.Printf(format, v...)
	}
}

func (r *RPCCompare) getBlockHash(url string, height int64) (string, error) {
	blockNumber := fmt.Sprintf("0x%x", height)

	req := RPCRequest{
		Jsonrpc: "2.0",
		Method:  "eth_getBlockByNumber",
		Params:  []interface{}{blockNumber, true},
		ID:      1,
	}

	reqBody, err := json.Marshal(req)
	if err != nil {
		return "", err
	}

	resp, err := r.client.Post(url, "application/json", bytes.NewBuffer(reqBody))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}

	var rpcResp RPCResponse
	if err := json.Unmarshal(body, &rpcResp); err != nil {
		return "", err
	}

	if rpcResp.Error != nil {
		return "", fmt.Errorf("RPC error: %s", rpcResp.Error.Message)
	}

	// Check if result is null
	if rpcResp.Result == nil {
		return "", fmt.Errorf("block at height %d does not exist (result is null)", height)
	}

	return rpcResp.Result.Hash, nil
}

func (r *RPCCompare) compareBlock(height int64) (bool, error) {
	hash1, err1 := r.getBlockHash(r.url1, height)
	hash2, err2 := r.getBlockHash(r.url2, height)

	// If both nodes return null (block doesn't exist on both), they are consistent
	if err1 != nil && err2 != nil {
		// Check if both errors are "result is null" errors
		if strings.Contains(err1.Error(), "does not exist") && strings.Contains(err2.Error(), "does not exist") {
			return true, nil
		}
		// One or both have other errors
		return false, fmt.Errorf("url1 error: %v, url2 error: %v", err1, err2)
	}

	// If one node returns null but the other has a hash, they are inconsistent
	if err1 != nil {
		if strings.Contains(err1.Error(), "does not exist") {
			r.logf("URL1: block at height %d does not exist", height)
			return false, nil
		}
		return false, err1
	}
	if err2 != nil {
		if strings.Contains(err2.Error(), "does not exist") {
			r.logf("URL2: block at height %d does not exist", height)
			return false, nil
		}
		return false, err2
	}

	return hash1 == hash2, nil
}

// binarySearch finds the first inconsistent height using binary search
func (r *RPCCompare) binarySearch() (int64, error) {
	left, right := r.startHeight, r.endHeight

	r.logf("Starting binary search: range [%d, %d]", left, right)

	// First, verify start height is consistent
	r.logf("Checking start height %d", r.startHeight)
	isConsistent, err := r.compareBlock(r.startHeight)
	if err != nil {
		return 0, err
	}
	if !isConsistent {
		r.logf("Start height %d is already inconsistent", r.startHeight)
		return r.startHeight, nil
	}
	r.logf("Start height %d is consistent", r.startHeight)

	// Then verify end height is inconsistent
	r.logf("Checking end height %d", r.endHeight)
	isConsistent, err = r.compareBlock(r.endHeight)
	if err != nil {
		return 0, err
	}
	if isConsistent {
		return 0, fmt.Errorf("all blocks from %d to %d are consistent", r.startHeight, r.endHeight)
	}
	r.logf("End height %d is inconsistent", r.endHeight)

	// Binary search for the first inconsistent height
	for left < right {
		mid := (left + right) / 2

		r.logf("Checking height %d", mid)
		isConsistent, err := r.compareBlock(mid)
		if err != nil {
			return 0, err
		}

		if isConsistent {
			// If consistent, the first inconsistency is after mid
			left = mid + 1
			r.logf("Height %d is consistent, narrowing to [%d, %d]", mid, left, right)
		} else {
			// If inconsistent, the first inconsistency is at or before mid
			right = mid
			r.logf("Height %d is inconsistent, narrowing to [%d, %d]", mid, left, right)
		}
	}

	r.logf("Found first inconsistent height: %d", left)
	return left, nil
}

func loadEnvFile(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			key := strings.TrimSpace(parts[0])
			value := strings.TrimSpace(parts[1])
			os.Setenv(key, value)
		}
	}

	return scanner.Err()
}

func main() {
	var (
		envFile     = flag.String("env", ".env", "Path to environment file")
		logFile     = flag.String("log", "", "Path to log file (if empty, logs to console)")
		url1        = flag.String("url1", "", "First RPC URL")
		url2        = flag.String("url2", "", "Second RPC URL")
		startHeight = flag.Int64("start", 0, "Start height to compare")
		endHeight   = flag.Int64("end", 0, "End height to compare")
	)
	flag.Parse()

	// Load environment file
	if err := loadEnvFile(*envFile); err != nil {
		fmt.Printf("Warning: could not load .env file: %v\n", err)
	}

	// Setup logging
	var logger *log.Logger

	if *logFile != "" {
		file, err := os.OpenFile(*logFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
		if err != nil {
			fmt.Printf("Error opening log file: %v\n", err)
			return
		}
		defer file.Close()
		// Write to both stdout and file
		logWriter := io.MultiWriter(os.Stdout, file)
		logger = log.New(logWriter, "", log.LstdFlags)
	} else {
		// Only write to stdout
		logger = log.New(os.Stdout, "", log.LstdFlags)
	}

	// Get configuration from environment or flags
	getEnvOrFlag := func(envKey string, flagValue string) string {
		if flagValue != "" {
			return flagValue
		}
		return os.Getenv(envKey)
	}

	url1Val := getEnvOrFlag("URL1", *url1)
	url2Val := getEnvOrFlag("URL2", *url2)

	if url1Val == "" {
		url1Val = "http://127.0.0.1:8123"
	}
	if url2Val == "" {
		url2Val = "https://testrpc.xlayer.tech"
	}

	var startVal, endVal int64
	if *startHeight != 0 {
		startVal = *startHeight
	} else if startEnv := os.Getenv("START_HEIGHT"); startEnv != "" {
		if val, err := strconv.ParseInt(startEnv, 10, 64); err == nil {
			startVal = val
		}
	} else {
		startVal = 12703783
	}

	if *endHeight != 0 {
		endVal = *endHeight
	} else if endEnv := os.Getenv("END_HEIGHT"); endEnv != "" {
		if val, err := strconv.ParseInt(endEnv, 10, 64); err == nil {
			endVal = val
		}
	} else {
		endVal = 12710000
	}

	logger.Printf("Comparing RPC nodes:")
	logger.Printf("  URL1: %s", url1Val)
	logger.Printf("  URL2: %s", url2Val)
	logger.Printf("  Range: %d - %d", startVal, endVal)
	logger.Printf("")

	comparer := NewRPCCompare(url1Val, url2Val, startVal, endVal, logger)

	firstInconsistent, err := comparer.binarySearch()
	if err != nil {
		logger.Printf("Error: %v", err)
		return
	}

	logger.Printf("")
	logger.Printf("First inconsistent height found: %d", firstInconsistent)
}
