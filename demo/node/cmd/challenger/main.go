// Package main implements the standalone challenger service.
// Auto-challenges every N outputs with full Cannon bisection support.
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
	"strconv"
	"syscall"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/ethereum-optimism/optimism/demo/core/mpt"
	"github.com/ethereum-optimism/optimism/demo/core/state"
	"github.com/ethereum-optimism/optimism/demo/core/types"
	"github.com/ethereum-optimism/optimism/demo/node/challenger"
	"github.com/ethereum-optimism/optimism/demo/node/l1"
)

func main() {
	// Parse flags
	l1RPC := flag.String("l1-rpc", getEnvOrDefault("L1_RPC", ""), "L1 RPC URL")
	x2RPC := flag.String("demo-rpc", getEnvOrDefault("DEMO_RPC", ""), "DEMO Node RPC URL")
	outputOracleAddr := flag.String("output-oracle", getEnvOrDefault("OUTPUT_ORACLE_ADDRESS", ""), "OutputOracle contract address")
	disputeFactoryAddr := flag.String("dispute-factory", getEnvOrDefault("DISPUTE_GAME_FACTORY_ADDRESS", ""), "DisputeGameFactory contract address")
	preimageOracleAddr := flag.String("preimage-oracle", getEnvOrDefault("PREIMAGE_ORACLE_ADDRESS", ""), "PreimageOracle contract address")
	mipsAddr := flag.String("mips", getEnvOrDefault("MIPS_ADDRESS", ""), "MIPS VM contract address")
	pollIntervalFlag := flag.Duration("poll-interval", 5*time.Second, "Poll interval")
	// Cannon configuration
	cannonPath := flag.String("cannon-path", getEnvOrDefault("CANNON_PATH", "/usr/local/bin/cannon"), "Path to cannon binary")
	programPath := flag.String("program-path", getEnvOrDefault("PROGRAM_PATH", "/app/bin/program.elf"), "Path to program.elf")
	cannonWorkDir := flag.String("cannon-work-dir", getEnvOrDefault("CANNON_WORK_DIR", "/cannon-work"), "Cannon work directory")

	challengeEveryN := uint64(100)
	if envN := os.Getenv("CHALLENGE_EVERY_N_OUTPUTS"); envN != "" {
		if n, err := strconv.ParseUint(envN, 10, 64); err == nil {
			challengeEveryN = n
		}
	}
	autoChallenge := getEnvOrDefault("AUTO_CHALLENGE", "true") == "true"
	flag.Parse()

	pollInterval := *pollIntervalFlag

	log.Println("=========================================")
	log.Println("  DEMO Cannon Challenger (Standalone)")
	log.Println("=========================================")
	log.Printf("L1 RPC: %s", *l1RPC)
	log.Printf("DEMO RPC: %s", *x2RPC)
	log.Printf("OutputOracle: %s", *outputOracleAddr)
	log.Printf("DisputeGameFactory: %s", *disputeFactoryAddr)
	log.Printf("PreimageOracle: %s", *preimageOracleAddr)
	log.Printf("MIPS: %s", *mipsAddr)
	log.Printf("Poll interval: %v", pollInterval)
	log.Printf("Challenge every N outputs: %d", challengeEveryN)
	log.Printf("Auto-challenge: %v", autoChallenge)
	log.Printf("Cannon path: %s", *cannonPath)
	log.Printf("Program path: %s", *programPath)
	log.Printf("Cannon work dir: %s", *cannonWorkDir)

	// Validate config
	if *l1RPC == "" {
		log.Fatal("L1_RPC is required")
	}
	if *x2RPC == "" {
		log.Fatal("DEMO_RPC is required")
	}

	// Create L1 client
	l1Config := &l1.Config{
		RPCURL:                    *l1RPC,
		ChainID:                   big.NewInt(31337),
		OutputOracleAddress:       l1.ParseAddress(*outputOracleAddr),
		DisputeGameFactoryAddress: l1.ParseAddress(*disputeFactoryAddr),
		PreimageOracleAddress:     l1.ParseAddress(*preimageOracleAddr),
		MIPSAddress:               l1.ParseAddress(*mipsAddr),
	}

	l1Client, err := l1.NewClient(l1Config)
	if err != nil {
		log.Fatalf("Failed to create L1 client: %v", err)
	}

	// Create state provider
	stateProvider := &DEMOStateProvider{x2RPC: *x2RPC}

	// Create challenger config with Cannon settings
	chalConfig := &challenger.Config{
		PollInterval:       pollInterval,
		ChallengeEveryN:    challengeEveryN,
		Honest:             true,
		AutoChallenge:      autoChallenge,
		DisputeGameFactory: l1.ParseAddress(*disputeFactoryAddr),
		// Cannon configuration - use local mode for real execution
		ProgramPath: *programPath,
		WorkDir:     *cannonWorkDir,
		CannonPath:  *cannonPath,
	}

	// Challenger address (Anvil account 3)
	chalAddr := l1.ParseAddress("0x90F79bf6EB2c4f870365E785982E1f101E93b906")

	// Create L1 adapter for challenger interface
	l1Adapter := &L1ClientAdapter{client: l1Client}

	// Create challenger
	chal := challenger.New(chalConfig, l1Adapter, stateProvider, chalAddr)

	// Create context for graceful shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Start challenger
	if err := chal.Start(ctx); err != nil {
		log.Fatalf("Failed to start challenger: %v", err)
	}

	log.Println("DEMO Cannon Challenger started successfully")
	log.Printf("Will auto-challenge every %d outputs", challengeEveryN)

	// Wait for shutdown signal
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh

	log.Println("Shutting down...")
	chal.Stop()
	log.Println("DEMO Cannon Challenger stopped")
}

func getEnvOrDefault(key, defaultValue string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultValue
}

// DEMOStateProvider implements challenger.StateProvider via RPC.
type DEMOStateProvider struct {
	x2RPC string
}

// GetVerifiableState gets verifiable state for a batch.
func (p *DEMOStateProvider) GetVerifiableState(batchIndex uint64) (*state.VerifiableState, error) {
	// Get batch info from DEMO node
	batch, err := p.fetchBatch(batchIndex)
	if err != nil {
		return nil, err
	}

	// Create verifiable state from batch
	vs := state.NewVerifiableState()
	if batch != nil {
		log.Printf("[StateProvider] Got batch %d: stateHash=%x mptRoot=%x",
			batchIndex, batch.FinalStateHash[:8], batch.MPTRoot[:8])
	}

	return vs, nil
}

// GenerateProof generates a proof for a key.
func (p *DEMOStateProvider) GenerateProof(batchIndex uint64, key []byte) (*mpt.Proof, error) {
	vs, err := p.GetVerifiableState(batchIndex)
	if err != nil {
		return nil, err
	}
	return vs.GenerateProof(key)
}

// ComputeMPTRoot computes the MPT root for a batch.
func (p *DEMOStateProvider) ComputeMPTRoot(batchIndex uint64) (types.Hash, error) {
	batch, err := p.fetchBatch(batchIndex)
	if err != nil {
		return types.Hash{}, err
	}
	if batch == nil {
		return types.Hash{}, fmt.Errorf("batch %d not found", batchIndex)
	}
	return batch.MPTRoot, nil
}

func (p *DEMOStateProvider) fetchBatch(index uint64) (*state.Batch, error) {
	reqBody := map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "x2_getBatchByIndex",
		"params":  []uint64{index},
		"id":      1,
	}

	body, err := json.Marshal(reqBody)
	if err != nil {
		return nil, err
	}

	resp, err := http.Post(p.x2RPC, "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	var rpcResp struct {
		Result *BatchResponse `json:"result"`
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

	if rpcResp.Result == nil {
		return nil, nil
	}

	r := rpcResp.Result
	return &state.Batch{
		BatchIndex:     r.BatchIndex,
		StartBlock:     r.StartBlock,
		EndBlock:       r.EndBlock,
		PrevStateHash:  parseHash(r.PrevStateHash),
		FinalStateHash: parseHash(r.FinalStateHash),
		MPTRoot:        parseHash(r.MPTRoot),
		TxDataHash:     parseHash(r.TxDataHash),
	}, nil
}

// GetCompletedBatches fetches completed batches from DEMO node.
func (p *DEMOStateProvider) GetCompletedBatches() ([]*state.Batch, error) {
	reqBody := map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "x2_getCompletedBatches",
		"params":  []interface{}{},
		"id":      1,
	}

	body, err := json.Marshal(reqBody)
	if err != nil {
		return nil, err
	}

	resp, err := http.Post(p.x2RPC, "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	var rpcResp struct {
		Result []*BatchResponse `json:"result"`
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

	batches := make([]*state.Batch, len(rpcResp.Result))
	for i, r := range rpcResp.Result {
		batches[i] = &state.Batch{
			BatchIndex:     r.BatchIndex,
			StartBlock:     r.StartBlock,
			EndBlock:       r.EndBlock,
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

// L1ClientAdapter adapts l1.Client to challenger.L1Client interface.
type L1ClientAdapter struct {
	client *l1.Client
}

func (a *L1ClientAdapter) CreateDisputeGame(ctx context.Context, batchIndex uint64, claimedRoot types.Hash) (common.Address, error) {
	return a.client.CreateDisputeGame(ctx, batchIndex, claimedRoot)
}

func (a *L1ClientAdapter) GetDisputeGame(ctx context.Context, gameAddr common.Address) (*challenger.DisputeGame, error) {
	game, err := a.client.GetDisputeGame(ctx, gameAddr)
	if err != nil || game == nil {
		return nil, err
	}
	return &challenger.DisputeGame{
		GameAddress: game.GameAddress,
		GameID:      game.GameID,
		BatchIndex:  game.BatchIndex,
		ClaimedRoot: game.ClaimedRoot,
		Status:      challenger.GameStatus(game.Status),
		Challenger:  game.Challenger,
		StartTime:   game.StartTime,
	}, nil
}

func (a *L1ClientAdapter) GetActiveGames(ctx context.Context) ([]*challenger.DisputeGame, error) {
	games, err := a.client.GetActiveGames(ctx)
	if err != nil {
		return nil, err
	}
	result := make([]*challenger.DisputeGame, len(games))
	for i, g := range games {
		result[i] = &challenger.DisputeGame{
			GameAddress: g.GameAddress,
			GameID:      g.GameID,
			BatchIndex:  g.BatchIndex,
			ClaimedRoot: g.ClaimedRoot,
			Status:      challenger.GameStatus(g.Status),
			Challenger:  g.Challenger,
			StartTime:   g.StartTime,
		}
	}
	return result, nil
}

func (a *L1ClientAdapter) HasActiveDispute(ctx context.Context, batchIndex uint64) (bool, error) {
	return a.client.HasActiveDispute(ctx, batchIndex)
}

func (a *L1ClientAdapter) GetOutputMPTRoot(ctx context.Context, batchIndex uint64) (types.Hash, error) {
	return a.client.GetOutputMPTRoot(ctx, batchIndex)
}

func (a *L1ClientAdapter) GetLatestOutputIndex() (uint64, error) {
	return a.client.GetLatestOutputIndex()
}

func (a *L1ClientAdapter) Attack(ctx context.Context, gameAddr common.Address, parentIndex uint64, claim types.Hash) error {
	return a.client.Attack(ctx, gameAddr, parentIndex, claim)
}

func (a *L1ClientAdapter) Defend(ctx context.Context, gameAddr common.Address, parentIndex uint64, claim types.Hash) error {
	return a.client.Defend(ctx, gameAddr, parentIndex, claim)
}

func (a *L1ClientAdapter) Step(ctx context.Context, gameAddr common.Address, claimIndex uint64, stateData, proof []byte, preStateHash, postStateHash common.Hash) error {
	return a.client.Step(ctx, gameAddr, claimIndex, stateData, proof, preStateHash, postStateHash)
}

func (a *L1ClientAdapter) Resolve(ctx context.Context, gameAddr common.Address) error {
	return a.client.Resolve(ctx, gameAddr)
}

func (a *L1ClientAdapter) CanResolve(ctx context.Context, gameAddr common.Address) (bool, error) {
	return a.client.CanResolve(ctx, gameAddr)
}

func (a *L1ClientAdapter) GetClaimCount(ctx context.Context, gameAddr common.Address) (uint64, error) {
	return a.client.GetClaimCount(ctx, gameAddr)
}
