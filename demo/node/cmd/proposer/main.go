// Package main implements the standalone proposer service.
// Includes defense capabilities for Cannon fault proofs.
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

	"github.com/ethereum/go-ethereum/common"

	"github.com/ethereum-optimism/optimism/demo/core/state"
	"github.com/ethereum-optimism/optimism/demo/core/types"
	"github.com/ethereum-optimism/optimism/demo/node/l1"
	"github.com/ethereum-optimism/optimism/demo/node/proposer"
)

func main() {
	// Parse flags
	l1RPC := flag.String("l1-rpc", getEnvOrDefault("L1_RPC", ""), "L1 RPC URL")
	x2RPC := flag.String("demo-rpc", getEnvOrDefault("DEMO_RPC", ""), "DEMO Node RPC URL")
	outputOracleAddr := flag.String("output-oracle", getEnvOrDefault("OUTPUT_ORACLE_ADDRESS", ""), "OutputOracle contract address")
	disputeFactoryAddr := flag.String("dispute-factory", getEnvOrDefault("DISPUTE_GAME_FACTORY_ADDRESS", ""), "DisputeGameFactory contract address")
	submitIntervalFlag := flag.Duration("submit-interval", 10*time.Second, "Output submission interval")
	defenseEnabled := getEnvOrDefault("DEFENSE_ENABLED", "true") == "true"
	flag.Parse()

	submitInterval := *submitIntervalFlag

	log.Println("=========================================")
	log.Println("  DEMO Proposer (Standalone)")
	log.Println("  with Cannon Defense Support")
	log.Println("=========================================")
	log.Printf("L1 RPC: %s", *l1RPC)
	log.Printf("DEMO RPC: %s", *x2RPC)
	log.Printf("OutputOracle: %s", *outputOracleAddr)
	log.Printf("DisputeGameFactory: %s", *disputeFactoryAddr)
	log.Printf("Submit interval: %v", submitInterval)
	log.Printf("Defense enabled: %v", defenseEnabled)

	// Validate config
	if *l1RPC == "" {
		log.Fatal("L1_RPC is required")
	}
	if *x2RPC == "" {
		log.Fatal("DEMO_RPC is required")
	}
	if *outputOracleAddr == "" {
		log.Fatal("OUTPUT_ORACLE_ADDRESS is required")
	}

	// Create L1 client
	l1Config := &l1.Config{
		RPCURL:                    *l1RPC,
		ChainID:                   big.NewInt(31337),
		OutputOracleAddress:       l1.ParseAddress(*outputOracleAddr),
		DisputeGameFactoryAddress: l1.ParseAddress(*disputeFactoryAddr),
	}

	l1Client, err := l1.NewClient(l1Config)
	if err != nil {
		log.Fatalf("Failed to create L1 client: %v", err)
	}

	// Create L1 adapter for proposer interface
	l1Adapter := &L1ClientAdapter{client: l1Client}

	// Create proposer config with defense capabilities
	propConfig := &proposer.Config{
		SubmitInterval:    submitInterval,
		OutputSubmitDelay: 1 * time.Second,
		ChallengeWindow:   5 * time.Minute,
		DefenseEnabled:    defenseEnabled,
		DefenseInterval:   5 * time.Second,
	}

	// Create proposer
	prop := proposer.New(propConfig, l1Adapter)

	// Create context for graceful shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Start proposer
	if err := prop.Start(ctx); err != nil {
		log.Fatalf("Failed to start proposer: %v", err)
	}

	log.Println("DEMO Proposer started successfully")
	if defenseEnabled {
		log.Println("Defense mode: ACTIVE - will defend against challenges")
	}

	// Poll DEMO node for new batches
	go pollBatches(ctx, *x2RPC, prop)

	// Wait for shutdown signal
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh

	log.Println("Shutting down...")
	prop.Stop()
	log.Println("DEMO Proposer stopped")
}

func getEnvOrDefault(key, defaultValue string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultValue
}

// L1ClientAdapter adapts l1.Client to proposer.L1Client interface.
type L1ClientAdapter struct {
	client *l1.Client
}

func (a *L1ClientAdapter) SubmitOutput(ctx context.Context, output *state.Output) error {
	return a.client.SubmitOutput(ctx, output)
}

func (a *L1ClientAdapter) GetLatestOutputIndex() (uint64, error) {
	return a.client.GetLatestOutputIndex()
}

func (a *L1ClientAdapter) HasActiveDispute(ctx context.Context, batchIndex uint64) (bool, error) {
	return a.client.HasActiveDispute(ctx, batchIndex)
}

func (a *L1ClientAdapter) GetOutputMPTRoot(ctx context.Context, batchIndex uint64) (types.Hash, error) {
	return a.client.GetOutputMPTRoot(ctx, batchIndex)
}

func (a *L1ClientAdapter) Defend(ctx context.Context, gameAddr common.Address, parentIndex uint64, claim types.Hash) error {
	return a.client.Defend(ctx, gameAddr, parentIndex, claim)
}

func (a *L1ClientAdapter) CanResolve(ctx context.Context, gameAddr common.Address) (bool, error) {
	return a.client.CanResolve(ctx, gameAddr)
}

func (a *L1ClientAdapter) Resolve(ctx context.Context, gameAddr common.Address) error {
	return a.client.Resolve(ctx, gameAddr)
}

func (a *L1ClientAdapter) GetClaimCount(ctx context.Context, gameAddr common.Address) (uint64, error) {
	return a.client.GetClaimCount(ctx, gameAddr)
}

// pollBatches polls the DEMO node for new batches.
func pollBatches(ctx context.Context, x2RPC string, prop *proposer.Proposer) {
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
				log.Printf("[Proposer] Failed to fetch batches: %v", err)
				continue
			}

			for _, batch := range batches {
				if batch.BatchIndex >= lastBatchIndex {
					log.Printf("[Proposer] Received batch %d from DEMO node (stateHash=%x, mptRoot=%x)",
						batch.BatchIndex, batch.FinalStateHash[:8], batch.MPTRoot[:8])
					prop.AddBatch(batch)
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
