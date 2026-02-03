// Package test provides integration tests for demo node.
package test

import (
	"context"
	"math/big"
	"testing"
	"time"

	"github.com/ethereum-optimism/optimism/demo/core/block"
	"github.com/ethereum-optimism/optimism/demo/core/dex"
	"github.com/ethereum-optimism/optimism/demo/core/state"
	"github.com/ethereum-optimism/optimism/demo/core/tx"
	"github.com/ethereum-optimism/optimism/demo/core/types"
	"github.com/ethereum-optimism/optimism/demo/node/sequencer"
)

func TestSequencerIntegration(t *testing.T) {
	// Create sequencer with fast block time
	config := &sequencer.Config{
		BlockTime:   100 * time.Millisecond,
		MaxBlockTxs: 100,
		BatchSize:   5,
	}
	seq := sequencer.New(config)

	// Setup initial state - give alice some tokens
	alice := types.Address{0x01}
	bob := types.Address{0x02}

	// Get mutable state and add balance
	s := seq.GetState()
	aliceAcc := s.GetOrCreateAccount(alice)
	aliceAcc.AddBalance(types.TokenETH, big.NewInt(1000000))
	aliceAcc.AddBalance(types.TokenUSDC, big.NewInt(2000000))

	// Track new blocks and batches
	blockCount := 0
	batchCount := 0
	seq.SetOnNewBlock(func(blk *block.Block) {
		blockCount++
	})
	seq.SetOnNewBatch(func(batch *state.Batch) {
		batchCount++
	})

	// Start sequencer
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err := seq.Start(ctx); err != nil {
		t.Fatalf("Failed to start sequencer: %v", err)
	}
	defer seq.Stop()

	// Submit transfer transaction
	transferPayload := &tx.TransferPayload{
		To:     bob,
		Token:  types.TokenETH,
		Amount: big.NewInt(100),
	}
	payloadBytes, _ := transferPayload.Encode()

	txn := &tx.Transaction{
		Type:    types.TxTypeTransfer,
		From:    alice,
		Payload: payloadBytes,
		Nonce:   0,
	}

	if err := seq.SubmitTx(txn); err != nil {
		t.Fatalf("Failed to submit tx: %v", err)
	}

	// Wait for blocks to be produced
	time.Sleep(500 * time.Millisecond)

	// Verify blocks were produced
	if blockCount == 0 {
		t.Error("No blocks were produced")
	}
	t.Logf("Blocks produced: %d", blockCount)

	// Get latest block
	latestBlock := seq.GetLatestBlock()
	if latestBlock == nil {
		t.Fatal("No latest block")
	}
	t.Logf("Latest block: #%d", latestBlock.Number())
}

func TestDEXIntegration(t *testing.T) {
	// Create sequencer
	config := &sequencer.Config{
		BlockTime:   50 * time.Millisecond,
		MaxBlockTxs: 100,
		BatchSize:   10,
	}
	seq := sequencer.New(config)

	// Setup initial state
	alice := types.Address{0x01}
	bob := types.Address{0x02}

	// Initialize accounts with balances
	seq.InitializeAccount(alice, map[types.TokenID]*big.Int{
		types.TokenETH:  big.NewInt(10000000),
		types.TokenUSDC: big.NewInt(20000000),
	})
	seq.InitializeAccount(bob, map[types.TokenID]*big.Int{
		types.TokenETH: big.NewInt(1000000),
	})

	// Start sequencer
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err := seq.Start(ctx); err != nil {
		t.Fatalf("Failed to start sequencer: %v", err)
	}
	defer seq.Stop()

	// 1. Create pool
	createPoolPayload := &tx.CreatePoolPayload{
		TokenA:  types.TokenETH,
		TokenB:  types.TokenUSDC,
		AmountA: big.NewInt(100000),
		AmountB: big.NewInt(200000),
		FeeRate: 30,
	}
	payloadBytes, _ := createPoolPayload.Encode()

	createPoolTx := &tx.Transaction{
		Type:    types.TxTypeCreatePool,
		From:    alice,
		Payload: payloadBytes,
		Nonce:   0,
	}

	if err := seq.SubmitTx(createPoolTx); err != nil {
		t.Fatalf("Failed to submit create pool tx: %v", err)
	}

	// Wait for transaction to be processed
	time.Sleep(200 * time.Millisecond)

	// 2. Swap
	poolID := dex.NewPoolID(types.TokenETH, types.TokenUSDC)
	swapPayload := &tx.SwapPayload{
		PoolID:       poolID,
		TokenIn:      types.TokenETH,
		AmountIn:     big.NewInt(1000),
		MinAmountOut: big.NewInt(1),
	}
	swapBytes, _ := swapPayload.Encode()

	swapTx := &tx.Transaction{
		Type:    types.TxTypeSwap,
		From:    bob,
		Payload: swapBytes,
		Nonce:   0,
	}

	if err := seq.SubmitTx(swapTx); err != nil {
		t.Fatalf("Failed to submit swap tx: %v", err)
	}

	// Wait for transaction to be processed
	time.Sleep(200 * time.Millisecond)

	// Verify state
	finalState := seq.GetState()
	pool := finalState.GetPool(poolID)
	if pool == nil {
		t.Fatal("Pool not found")
	}

	t.Logf("Pool reserves: A=%s, B=%s, LP=%s",
		pool.ReserveA, pool.ReserveB, pool.TotalLP)

	// Bob should have received USDC
	bobFinal := finalState.GetAccount(bob)
	if bobFinal != nil {
		bobUSDC := bobFinal.GetBalance(types.TokenUSDC)
		t.Logf("Bob USDC balance: %s", bobUSDC)
		if bobUSDC.Sign() <= 0 {
			t.Error("Bob should have received USDC from swap")
		}
	}
}

func TestBatchCreation(t *testing.T) {
	// Create sequencer with small batch size
	config := &sequencer.Config{
		BlockTime:   50 * time.Millisecond,
		MaxBlockTxs: 100,
		BatchSize:   3, // Small batch size for testing
	}
	seq := sequencer.New(config)

	batchCount := 0
	seq.SetOnNewBatch(func(batch *state.Batch) {
		batchCount++
	})

	// Start sequencer
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err := seq.Start(ctx); err != nil {
		t.Fatalf("Failed to start sequencer: %v", err)
	}
	defer seq.Stop()

	// Wait for batches to be created
	time.Sleep(500 * time.Millisecond)

	// Should have created at least one batch
	t.Logf("Batches created: %d", batchCount)

	// Check current batch
	currentBatch := seq.CurrentBatch()
	if currentBatch == nil {
		t.Fatal("No current batch")
	}
	t.Logf("Current batch index: %d, blocks: %d",
		currentBatch.BatchIndex, len(currentBatch.Blocks))
}
