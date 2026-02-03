// Package main implements the standalone batcher service.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/ethereum-optimism/optimism/demo/core/state"
	"github.com/ethereum-optimism/optimism/demo/core/types"
	"github.com/ethereum-optimism/optimism/demo/node/batcher"
	"github.com/ethereum-optimism/optimism/demo/node/l1"
)

func main() {
	// Parse flags
	l1RPC := flag.String("l1-rpc", os.Getenv("L1_RPC"), "L1 RPC URL")
	x2RPC := flag.String("demo-rpc", os.Getenv("DEMO_RPC"), "DEMO Node RPC URL")
	batchInboxAddr := flag.String("batch-inbox", os.Getenv("BATCH_INBOX_ADDRESS"), "BatchInbox contract address")
	submitInterval := flag.Duration("submit-interval", 10*time.Second, "Batch submission interval")
	flag.Parse()

	log.Println("=========================================")
	log.Println("  Starting DEMO Batcher (Standalone)")
	log.Println("=========================================")
	log.Printf("L1 RPC: %s", *l1RPC)
	log.Printf("DEMO RPC: %s", *x2RPC)
	log.Printf("BatchInbox: %s", *batchInboxAddr)
	log.Printf("Submit interval: %v", *submitInterval)

	// Validate config
	if *l1RPC == "" {
		log.Fatal("L1_RPC is required")
	}
	if *x2RPC == "" {
		log.Fatal("DEMO_RPC is required")
	}
	if *batchInboxAddr == "" {
		log.Fatal("BATCH_INBOX_ADDRESS is required")
	}

	// Create L1 client
	l1Config := &l1.Config{
		RPCURL:            *l1RPC,
		ChainID:           big.NewInt(31337),
		BatchInboxAddress: l1.ParseAddress(*batchInboxAddr),
	}

	l1Client, err := l1.NewClient(l1Config)
	if err != nil {
		log.Fatalf("Failed to create L1 client: %v", err)
	}

	// Create batcher config
	batConfig := &batcher.Config{
		SubmitInterval: *submitInterval,
		MaxBatchSize:   120000,
	}

	// Create batcher
	bat := batcher.New(batConfig, l1Client)

	// Create context for graceful shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Start batcher
	if err := bat.Start(ctx); err != nil {
		log.Fatalf("Failed to start batcher: %v", err)
	}

	log.Println("DEMO Batcher started successfully")

	// Poll DEMO node for new batches
	go pollBatches(ctx, *x2RPC, bat)

	// Wait for shutdown signal
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh

	log.Println("Shutting down...")
	bat.Stop()
	log.Println("DEMO Batcher stopped")
}

// pollBatches polls the DEMO node for new batches.
func pollBatches(ctx context.Context, x2RPC string, bat *batcher.Batcher) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	var lastBatchIndex uint64 = 0

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// Get completed batches from DEMO node via RPC
			batches, err := fetchCompletedBatches(x2RPC, lastBatchIndex)
			if err != nil {
				log.Printf("[Batcher] Failed to fetch batches: %v", err)
				continue
			}

			for _, batch := range batches {
				if batch.BatchIndex >= lastBatchIndex {
					log.Printf("[Batcher] Received batch %d from DEMO node (blocks=%d)",
						batch.BatchIndex, len(batch.Blocks))
					bat.AddBatch(batch)
					lastBatchIndex = batch.BatchIndex + 1
				}
			}
		}
	}
}

// fetchCompletedBatches fetches completed batches from DEMO node via RPC.
func fetchCompletedBatches(x2RPC string, fromIndex uint64) ([]*state.Batch, error) {
	reqBody := map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "x2_getCompletedBatches",
		"params":  []uint64{fromIndex},
		"id":      1,
	}

	body, err := json.Marshal(reqBody)
	if err != nil {
		return nil, err
	}

	resp, err := http.Post(x2RPC, "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	var rpcResp struct {
		Result []BatchResponse `json:"result"`
		Error  *struct {
			Message string `json:"message"`
		} `json:"error"`
	}

	if err := json.Unmarshal(respBody, &rpcResp); err != nil {
		return nil, err
	}

	if rpcResp.Error != nil {
		return nil, fmt.Errorf("RPC error: %s", rpcResp.Error.Message)
	}

	// Convert responses to state.Batch
	batches := make([]*state.Batch, len(rpcResp.Result))
	for i, r := range rpcResp.Result {
		batches[i] = &state.Batch{
			BatchIndex:     r.BatchIndex,
			StartBlock:     r.StartBlock,
			EndBlock:       r.EndBlock,
			Blocks:         make([]state.BlockData, r.BlockCount),
			PrevStateHash:  parseHash(r.PrevStateHash),
			FinalStateHash: parseHash(r.FinalStateHash),
			MPTRoot:        parseHash(r.MPTRoot),
			TxDataHash:     parseHash(r.TxDataHash),
		}
	}

	return batches, nil
}

// BatchResponse represents the RPC response for a batch.
type BatchResponse struct {
	BatchIndex     uint64 `json:"batchIndex"`
	StartBlock     uint64 `json:"startBlock"`
	EndBlock       uint64 `json:"endBlock"`
	BlockCount     int    `json:"blockCount"`
	PrevStateHash  string `json:"prevStateHash"`
	FinalStateHash string `json:"finalStateHash"`
	MPTRoot        string `json:"mptRoot"`
	TxDataHash     string `json:"txDataHash"`
}

func parseHash(s string) types.Hash {
	var h types.Hash
	if len(s) >= 2 && s[:2] == "0x" {
		s = s[2:]
	}
	for i := 0; i < len(s)/2 && i < 32; i++ {
		fmt.Sscanf(s[i*2:i*2+2], "%02x", &h[i])
	}
	return h
}
