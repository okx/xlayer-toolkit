package tx

import (
	"math/big"
	"testing"

	"github.com/ethereum-optimism/optimism/demo/core/dex"
	"github.com/ethereum-optimism/optimism/demo/core/state"
	"github.com/ethereum-optimism/optimism/demo/core/types"
)

func TestTransfer(t *testing.T) {
	// Create state
	s := state.NewState()

	// Create accounts
	alice := types.Address{0x01}
	bob := types.Address{0x02}

	aliceAcc := s.GetOrCreateAccount(alice)
	aliceAcc.AddBalance(types.TokenETH, big.NewInt(1000))

	// Create transfer transaction
	payload := &TransferPayload{
		To:     bob,
		Token:  types.TokenETH,
		Amount: big.NewInt(100),
	}
	payloadBytes, _ := payload.Encode()

	tx := &Transaction{
		Type:    types.TxTypeTransfer,
		From:    alice,
		Payload: payloadBytes,
		Nonce:   0,
	}

	// Execute
	executor := NewExecutor()
	result := executor.Execute(s, tx)

	if !result.Success {
		t.Fatalf("Transfer failed: %v", result.Error)
	}

	// Verify balances
	aliceBalance := s.GetAccount(alice).GetBalance(types.TokenETH)
	bobBalance := s.GetAccount(bob).GetBalance(types.TokenETH)

	if aliceBalance.Cmp(big.NewInt(900)) != 0 {
		t.Errorf("Alice balance mismatch: got %s, want 900", aliceBalance)
	}
	if bobBalance.Cmp(big.NewInt(100)) != 0 {
		t.Errorf("Bob balance mismatch: got %s, want 100", bobBalance)
	}
}

func TestCreatePoolAndSwap(t *testing.T) {
	// Create state
	s := state.NewState()

	// Create account with tokens
	alice := types.Address{0x01}
	aliceAcc := s.GetOrCreateAccount(alice)
	aliceAcc.AddBalance(types.TokenETH, big.NewInt(1000000))
	aliceAcc.AddBalance(types.TokenUSDC, big.NewInt(2000000))

	executor := NewExecutor()

	// Create pool ETH/USDC
	createPoolPayload := &CreatePoolPayload{
		TokenA:  types.TokenETH,
		TokenB:  types.TokenUSDC,
		AmountA: big.NewInt(1000),
		AmountB: big.NewInt(2000),
		FeeRate: 30, // 0.3%
	}
	createPoolBytes, _ := createPoolPayload.Encode()

	createPoolTx := &Transaction{
		Type:    types.TxTypeCreatePool,
		From:    alice,
		Payload: createPoolBytes,
		Nonce:   0,
	}

	result := executor.Execute(s, createPoolTx)
	if !result.Success {
		t.Fatalf("Create pool failed: %v", result.Error)
	}

	// Verify pool was created
	poolID := dex.NewPoolID(types.TokenETH, types.TokenUSDC)
	pool := s.GetPool(poolID)
	if pool == nil {
		t.Fatal("Pool not found")
	}

	t.Logf("Pool created: ReserveA=%s, ReserveB=%s, TotalLP=%s",
		pool.ReserveA, pool.ReserveB, pool.TotalLP)

	// Swap 10 ETH for USDC
	swapPayload := &SwapPayload{
		PoolID:       poolID,
		TokenIn:      types.TokenETH,
		AmountIn:     big.NewInt(10),
		MinAmountOut: big.NewInt(1), // Low slippage protection for test
	}
	swapBytes, _ := swapPayload.Encode()

	swapTx := &Transaction{
		Type:    types.TxTypeSwap,
		From:    alice,
		Payload: swapBytes,
		Nonce:   1,
	}

	result = executor.Execute(s, swapTx)
	if !result.Success {
		t.Fatalf("Swap failed: %v", result.Error)
	}

	// Verify swap happened
	aliceETH := aliceAcc.GetBalance(types.TokenETH)
	aliceUSDC := aliceAcc.GetBalance(types.TokenUSDC)

	t.Logf("After swap: Alice ETH=%s, USDC=%s", aliceETH, aliceUSDC)
	t.Logf("Pool: ReserveA=%s, ReserveB=%s", pool.ReserveA, pool.ReserveB)

	// Alice should have less ETH and more USDC than initial (after pool creation)
	// Initial: 1000000 ETH, 2000000 USDC
	// After pool: 999000 ETH, 1998000 USDC
	// After swap: 998990 ETH, ~1998019 USDC (gained ~19 USDC for 10 ETH)
	expectedETH := big.NewInt(998990)
	if aliceETH.Cmp(expectedETH) != 0 {
		t.Errorf("Alice ETH mismatch: got %s, want %s", aliceETH, expectedETH)
	}
}

func TestAddAndRemoveLiquidity(t *testing.T) {
	// Create state
	s := state.NewState()

	// Create accounts
	alice := types.Address{0x01}
	bob := types.Address{0x02}

	aliceAcc := s.GetOrCreateAccount(alice)
	aliceAcc.AddBalance(types.TokenETH, big.NewInt(10000))
	aliceAcc.AddBalance(types.TokenUSDC, big.NewInt(20000))

	bobAcc := s.GetOrCreateAccount(bob)
	bobAcc.AddBalance(types.TokenETH, big.NewInt(5000))
	bobAcc.AddBalance(types.TokenUSDC, big.NewInt(10000))

	executor := NewExecutor()

	// Alice creates pool
	createPoolPayload := &CreatePoolPayload{
		TokenA:  types.TokenETH,
		TokenB:  types.TokenUSDC,
		AmountA: big.NewInt(1000),
		AmountB: big.NewInt(2000),
		FeeRate: 30,
	}
	createPoolBytes, _ := createPoolPayload.Encode()

	result := executor.Execute(s, &Transaction{
		Type:    types.TxTypeCreatePool,
		From:    alice,
		Payload: createPoolBytes,
		Nonce:   0,
	})
	if !result.Success {
		t.Fatalf("Create pool failed: %v", result.Error)
	}

	poolID := dex.NewPoolID(types.TokenETH, types.TokenUSDC)
	pool := s.GetPool(poolID)

	// Bob adds liquidity
	addLiqPayload := &AddLiquidityPayload{
		PoolID:  poolID,
		AmountA: big.NewInt(500),
		AmountB: big.NewInt(1000),
		MinLP:   big.NewInt(1),
	}
	addLiqBytes, _ := addLiqPayload.Encode()

	result = executor.Execute(s, &Transaction{
		Type:    types.TxTypeAddLiquidity,
		From:    bob,
		Payload: addLiqBytes,
		Nonce:   0,
	})
	if !result.Success {
		t.Fatalf("Add liquidity failed: %v", result.Error)
	}

	bobLP := bobAcc.GetBalance(pool.LPTokenID())
	t.Logf("Bob LP tokens: %s", bobLP)

	if bobLP.Sign() <= 0 {
		t.Error("Bob should have LP tokens")
	}

	// Bob removes liquidity
	removeLiqPayload := &RemoveLiquidityPayload{
		PoolID:   poolID,
		LPAmount: bobLP,
		MinA:     big.NewInt(1),
		MinB:     big.NewInt(1),
	}
	removeLiqBytes, _ := removeLiqPayload.Encode()

	result = executor.Execute(s, &Transaction{
		Type:    types.TxTypeRemoveLiquidity,
		From:    bob,
		Payload: removeLiqBytes,
		Nonce:   1,
	})
	if !result.Success {
		t.Fatalf("Remove liquidity failed: %v", result.Error)
	}

	// Bob should have no LP tokens left
	bobLP = bobAcc.GetBalance(pool.LPTokenID())
	if bobLP.Sign() != 0 {
		t.Errorf("Bob should have 0 LP tokens, got %s", bobLP)
	}

	t.Logf("After remove: Bob ETH=%s, USDC=%s",
		bobAcc.GetBalance(types.TokenETH),
		bobAcc.GetBalance(types.TokenUSDC))
}
