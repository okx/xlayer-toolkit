//go:build !skip_smoke
// +build !skip_smoke

package e2e

import (
	"context"
	"fmt"
	"math/big"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/log"
	"github.com/ethereum/go-ethereum/params"
	"github.com/ethereum/go-ethereum/rpc"
	"github.com/holiman/uint256"
	"github.com/okx/op-geth/test/constants"
	"github.com/okx/op-geth/test/operations"
	"github.com/stretchr/testify/require"
)

const (
	Gwei         = 1000000000
	testVerified = true
)

func TestSendTx(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}
	ctx := context.Background()
	client, err := ethclient.Dial(operations.DefaultL2NetworkURL)
	require.NoError(t, err)
	TransToken(t, ctx, client, uint256.NewInt(params.GWei), operations.DefaultRichAddress)

	from := common.HexToAddress(operations.DefaultRichAddress)
	to := common.HexToAddress(operations.DefaultRichAddress)
	nonce, err := client.PendingNonceAt(ctx, from)
	require.NoError(t, err)
	gas, err := client.EstimateGas(ctx, ethereum.CallMsg{
		From:  from,
		To:    &to,
		Value: big.NewInt(10),
	})
	require.NoError(t, err)
	tx := types.NewTransaction(nonce, to, big.NewInt(10), gas, big.NewInt(100*params.GWei), nil)
	privateKey, err := crypto.HexToECDSA(strings.TrimPrefix(operations.DefaultRichPrivateKey, "0x"))
	require.NoError(t, err)

	signer := types.MakeSigner(operations.GetTestChainConfig(operations.DefaultL2ChainID), big.NewInt(1), 0)
	signedTx, err := types.SignTx(tx, signer, privateKey)
	require.NoError(t, err)

	err = client.SendTransaction(ctx, signedTx)
	require.NoError(t, err)

	err = operations.WaitTxToBeMined(ctx, client, signedTx, operations.DefaultTimeoutTxToBeMined)
	require.NoError(t, err)
}

func TestChainID(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}
	chainID, err := operations.EthChainID()
	require.NoError(t, err)
	require.Equal(t, chainID, operations.DefaultL2ChainID)
}

func TestEthTransfer(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}

	if !testVerified {
		return
	}

	ctx := context.Background()
	auth, err := operations.GetAuth(operations.DefaultRichPrivateKey, operations.DefaultL2ChainID)
	require.NoError(t, err)
	client, err := ethclient.Dial(operations.DefaultL2NetworkURL)
	require.NoError(t, err)

	from := common.HexToAddress(operations.DefaultRichAddress)
	to := common.HexToAddress(operations.DefaultL2NewAcc1Address)
	nonce, err := client.PendingNonceAt(ctx, from)
	require.NoError(t, err)
	tx := types.NewTransaction(nonce, to, big.NewInt(0), 21000, big.NewInt(10*params.GWei), nil)
	privateKey, err := crypto.HexToECDSA(strings.TrimPrefix(operations.DefaultRichPrivateKey, "0x"))
	require.NoError(t, err)
	signer := types.MakeSigner(operations.GetTestChainConfig(operations.DefaultL2ChainID), big.NewInt(1), 0)
	signedTx, err := types.SignTx(tx, signer, privateKey)
	require.NoError(t, err)
	var txs []*types.Transaction
	txs = append(txs, signedTx)
	_, err = operations.ApplyL2Txs(ctx, txs, auth, client, operations.VerifiedConfirmationLevel)
	require.NoError(t, err)
}

func TestDebugTraceRPC(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}

	// Wait for at least one block to be available
	var blockNumber uint64
	var err error
	for i := 0; i < 30; i++ {
		blockNumber, err = operations.GetBlockNumber()
		require.NoError(t, err)
		log.Info("Block number: %d, attempt: %v", blockNumber, i)
		if blockNumber > 3 {
			break
		}
		time.Sleep(1 * time.Second)
	}
	require.Greater(t, blockNumber, uint64(0), "Block number should be greater than 0")

	// Get a block to trace
	blockNum, err := operations.GetBlockNumber()
	require.NoError(t, err)

	// Use the working RPC method instead of the broken GetBlockByNumber
	blockNumberHex := fmt.Sprintf("0x%x", blockNum)
	blockData, err := operations.EthGetBlockByNumber(blockNumberHex, true)
	require.NoError(t, err)
	require.NotNil(t, blockData, "Block data should not be nil")

	blockHash := common.Hash{}
	if blockMap, ok := blockData.(map[string]interface{}); ok {
		if hashStr, exists := blockMap["hash"].(string); exists && hashStr != "" {
			blockHash = common.HexToHash(hashStr)
		}
	}

	// Test debug_traceBlockByHash
	t.Run("DebugTraceBlockByHash", func(t *testing.T) {
		require.NotEqual(t, common.Hash{}, blockHash, "Block hash should not be empty")

		traceResult, err := operations.DebugTraceBlockByHash(blockHash)
		require.NoError(t, err)
		require.NotNil(t, traceResult, "Trace result should not be nil")

		log.Info("DebugTraceBlockByHash result type: %T", traceResult)
	})

	// Test debug_traceBlockByNumber
	t.Run("DebugTraceBlockByNumber", func(t *testing.T) {
		traceResult, err := operations.DebugTraceBlockByNumber(blockNum)
		require.NoError(t, err)
		require.NotNil(t, traceResult, "Trace result should not be nil")

		log.Info("DebugTraceBlockByNumber result type: %T", traceResult)
	})

	// Test debug_traceTransaction
	t.Run("DebugTraceTransaction", func(t *testing.T) {
		blockInfo, err := operations.EthGetBlockByHash(blockHash, true)
		require.NoError(t, err)
		var blockInfoMap map[string]interface{}
		var txsInterface interface{}
		var txs []interface{}
		var txMap map[string]interface{}
		var txHashStr string
		var exists bool
		var ok bool

		if blockInfoMap, ok = blockInfo.(map[string]interface{}); !ok {
			t.Error("Block info not in expected format")
		}
		if txsInterface, exists = blockInfoMap["transactions"]; !exists {
			t.Error("Transactions field not found in block data")
		}

		if txs, ok = txsInterface.([]interface{}); !ok || len(txs) == 0 {
			t.Error("No transactions found in block")
		}

		if txMap, ok = txs[0].(map[string]interface{}); !ok {
			t.Error("Transaction data not in expected format")
		}

		if txHashStr, exists = txMap["hash"].(string); !exists {
			t.Error("Transaction hash not found in transaction data")
		}

		txHash := common.HexToHash(txHashStr)
		require.NotEqual(t, common.Hash{}, txHash, "Transaction hash should not be empty")

		traceResult, err := operations.DebugTraceTransaction(txHash)
		require.NoError(t, err)
		require.NotNil(t, traceResult, "Trace result should not be nil")

		log.Info("DebugTraceTransaction result type: %T", traceResult)
	})
}

// TestEthereumBasicRPC tests basic Ethereum RPC methods
func TestEthereumBasicRPC(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}

	_, _ = SetupTestEnvironment(t)

	// Default test address for tests that require an address
	testAddress := common.HexToAddress("0x1234567890123456789012345678901234567890")

	// Test eth_chainId
	t.Run("EthChainID", func(t *testing.T) {
		chainID, err := operations.EthChainID()
		require.NoError(t, err)
		require.NotEqual(t, uint64(0), chainID, "Chain ID should not be zero")
		log.Info("EthChainID result: %d", chainID)
	})

	// Test eth_syncing
	t.Run("EthSyncing", func(t *testing.T) {
		syncing, err := operations.EthSyncing()
		require.NoError(t, err)
		log.Info("EthSyncing result: %t", syncing)
	})

	// Test eth_getBalance
	t.Run("EthGetBalance", func(t *testing.T) {
		balance, err := operations.EthGetBalance(testAddress, "latest")
		require.NoError(t, err)
		log.Info("EthGetBalance result for test address: %s", balance.String())
	})

	// Test eth_getCode
	t.Run("EthGetCode", func(t *testing.T) {
		code, err := operations.EthGetCode(testAddress, "latest")
		require.NoError(t, err)
		log.Info("EthGetCode result length: %d", len(code))
	})

	// Test eth_getTransactionCount
	t.Run("EthGetTransactionCount", func(t *testing.T) {
		txCount, err := operations.EthGetTransactionCount(testAddress, "latest")
		require.NoError(t, err)
		log.Info("EthGetTransactionCount result: %d", txCount)
	})

	// Test eth_blockNumber
	t.Run("EthBlockNumber", func(t *testing.T) {
		blockNumber, err := operations.EthBlockNumber()
		require.NoError(t, err)
		require.Greater(t, blockNumber, uint64(0), "Block number should be greater than 0")
		log.Info("EthBlockNumber result: %d", blockNumber)
	})

	// Test eth_gasPrice
	t.Run("EthGasPrice", func(t *testing.T) {
		gasPrice, err := operations.EthGasPrice()
		require.NoError(t, err)
		require.Greater(t, gasPrice.Cmp(big.NewInt(0)), 0, "Gas price should be greater than 0")
		log.Info("EthGasPrice result: %s", gasPrice.String())
	})

	// Test eth_getStorageAt
	t.Run("EthGetStorageAt", func(t *testing.T) {
		storage, err := operations.EthGetStorageAt(testAddress, "0x0", "latest")
		require.NoError(t, err)
		log.Info("EthGetStorageAt result: %s", storage)
	})
}

// TestEthereumBlockRPC tests Ethereum block-related RPC methods
func TestEthereumBlockRPC(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}
	EnsureContractsDeployed(t)

	blockHash, blockNumber := SetupTestEnvironment(t)
	ctx := context.Background()
	client, err := ethclient.Dial(operations.DefaultL2NetworkURL)
	require.NoError(t, err)
	defer client.Close()

	toAddr := common.HexToAddress(operations.DefaultL2NewAcc1Address)

	// Test eth_getBlockByHash
	t.Run("EthGetBlockByHash", func(t *testing.T) {
		block, err := operations.EthGetBlockByHash(blockHash, true)
		require.NoError(t, err)
		require.NotNil(t, block, "Block should not be nil")
		log.Info("EthGetBlockByHash result type: %T", block)
	})

	// Test eth_getBlockByNumber
	t.Run("EthGetBlockByNumber", func(t *testing.T) {
		blockNumberHex := fmt.Sprintf("0x%x", blockNumber)
		block, err := operations.EthGetBlockByNumber(blockNumberHex, true)
		require.NoError(t, err)
		require.NotNil(t, block, "Block should not be nil")
		log.Info("EthGetBlockByNumber result type: %T", block)
	})

	// Test eth_getBlockTransactionCountByHash
	t.Run("EthGetBlockTransactionCountByHash", func(t *testing.T) {
		txCount, err := operations.EthGetBlockTransactionCountByHash(blockHash)
		require.NoError(t, err)
		log.Info("EthGetBlockTransactionCountByHash result: %d", txCount)
	})

	// Test eth_getBlockTransactionCountByNumber
	t.Run("EthGetBlockTransactionCountByNumber", func(t *testing.T) {
		// Use current block instead of pruned block #1
		currentBlockHex := fmt.Sprintf("0x%x", blockNumber)
		txCount, err := operations.EthGetBlockTransactionCountByNumber(currentBlockHex)
		require.NoError(t, err)
		log.Info("EthGetBlockTransactionCountByNumber result: %d", txCount)
	})

	// Test eth_getTransactionByBlockHashAndIndex
	t.Run("EthGetTransactionByBlockHashAndIndex", func(t *testing.T) {
		tx, err := operations.EthGetTransactionByBlockHashAndIndex(blockHash, "0x0")
		require.NoError(t, err)
		log.Info("EthGetTransactionByBlockHashAndIndex result type: %T", tx)
	})

	// Test eth_getTransactionByBlockNumberAndIndex
	t.Run("EthGetTransactionByBlockNumberAndIndex", func(t *testing.T) {
		// Use current block instead of pruned block #1
		currentBlockHex := fmt.Sprintf("0x%x", blockNumber)
		tx, err := operations.EthGetTransactionByBlockNumberAndIndex(currentBlockHex, "0x0")
		require.NoError(t, err)
		require.NotNil(t, tx, "Transaction should not be nil")
		log.Info("EthGetTransactionByBlockNumberAndIndex result type: %T", tx)
	})

	t.Run("EthGetBlockReceipts", func(t *testing.T) {
		numberOfTransactions := 10
		_, targetBlockNumber, targetBlockHash := transErc20TokenBatch(t, context.Background(), client, ERC20Addr, big.NewInt(Gwei), toAddr.String(), numberOfTransactions)

		// Test getting receipts by number
		receiptsByNumber, err := client.BlockReceipts(ctx, rpc.BlockNumberOrHashWithNumber(rpc.BlockNumber(targetBlockNumber)))
		require.NoError(t, err)
		require.NotNil(t, receiptsByNumber, "Transaction receipts by number should not be nil")
		for _, receipt := range receiptsByNumber {
			require.NoError(t, err)
			require.NotNil(t, receipt)
			log.Info(fmt.Sprintf("RealtimeGetBlockReceiptsByNumber result type: %T", receipt))
		}

		// Test getting receipts by hash
		receiptsByHash, err := client.BlockReceipts(ctx, rpc.BlockNumberOrHashWithHash(targetBlockHash, true))
		require.NoError(t, err)
		require.NotNil(t, receiptsByHash, "Transaction receipts by hash should not be nil")
		for _, receipt := range receiptsByHash {
			require.NoError(t, err)
			require.NotNil(t, receipt)
			log.Info(fmt.Sprintf("RealtimeGetBlockReceiptsByHash result type: %T", receipt))
		}
	})
}

// TestEthereumTransactionRPC tests Ethereum transaction-related RPC methods
func TestEthereumTransactionRPC(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}
	EnsureContractsDeployed(t)
	fromAddr := common.HexToAddress(operations.DefaultRichAddress)
	toAddr := common.HexToAddress(operations.DefaultL2NewAcc1Address)

	ctx := context.Background()
	client, err := ethclient.Dial(operations.DefaultL2NetworkURL)
	require.NoError(t, err)
	defer client.Close()

	txhash := TransToken(t, ctx, client, uint256.NewInt(params.GWei), operations.DefaultRichAddress)
	fmt.Printf("TransToken txhash: %s\n", txhash)

	t.Run("EthEstimateGas", func(t *testing.T) {
		balance, err := client.BalanceAt(ctx, fromAddr, nil)
		require.NoError(t, err)
		require.Greater(t, balance.Cmp(big.NewInt(0)), 0, "From address should have balance")

		t.Run("SimpleTransfer", func(t *testing.T) {
			transferAmount := big.NewInt(1000000000000000)

			gas, err := client.EstimateGas(ctx, ethereum.CallMsg{
				From:  fromAddr,
				To:    &toAddr,
				Value: transferAmount,
			})
			require.NoError(t, err)
			require.Equal(t, uint64(21000), gas, "Simple transfer should use exactly 21000 gas")

			fmt.Printf("EthEstimateGas SimpleTransfer result: %d gas\n", gas)
		})

		// Test 2: Contract call gas estimation
		t.Run("ContractCall", func(t *testing.T) {
			contractAABI, err := abi.JSON(strings.NewReader(constants.ContractAABIJson))
			require.NoError(t, err)
			calldata, err := contractAABI.Pack("triggerCall")
			require.NoError(t, err)

			gas, err := client.EstimateGas(ctx, ethereum.CallMsg{
				From: fromAddr,
				To:   &ContractAAddr,
				Data: calldata,
			})
			require.NoError(t, err)
			require.Greater(t, gas, uint64(21000), "Contract call should use more than 21000 gas")

			fmt.Printf("EthEstimateGas ContractCall result: %d gas\n", gas)
		})
	})

	t.Run("EthCall", func(t *testing.T) {
		// Get balance before the call
		balanceBefore, err := client.BalanceAt(ctx, fromAddr, nil)
		require.NoError(t, err)
		require.Greater(t, balanceBefore.Cmp(big.NewInt(0)), 0, "From address should have balance")

		contractCABI, err := abi.JSON(strings.NewReader(constants.ContractCABIJson))
		require.NoError(t, err)
		calldata, err := contractCABI.Pack("getValue")
		require.NoError(t, err)

		result, err := client.CallContract(ctx, ethereum.CallMsg{
			From: fromAddr,
			To:   &ContractCAddr,
			Data: calldata,
		}, nil)
		require.NoError(t, err)
		require.NotNil(t, result, "Call result should not be nil")

		balanceAfter, err := client.BalanceAt(ctx, fromAddr, nil)
		require.NoError(t, err)
		require.Equal(t, balanceBefore.String(), balanceAfter.String(), "Balance should remain unchanged after eth_call")
	})

	t.Run("EthGetTransactionByHash", func(t *testing.T) {
		result, err := operations.EthGetTransactionByHash(common.HexToHash(txhash))
		require.NoError(t, err)

		txData, _ := result.(map[string]interface{})

		receipt, err := client.TransactionReceipt(ctx, common.HexToHash(txhash))
		require.NoError(t, err)
		require.NotNil(t, receipt, "Receipt should not be nil")

		txHashStr, exists := txData["hash"].(string)
		require.True(t, exists, "Transaction should have hash field")
		require.Equal(t, txhash, txHashStr, "Transaction hash should match")

		txIndexHex := txData["transactionIndex"].(string)
		txIndex, err := hexutil.DecodeUint64(txIndexHex)
		require.NoError(t, err, "Transaction index should be valid hex")
		require.Equal(t, uint64(receipt.TransactionIndex), txIndex, "Transaction index should match between transaction and receipt")

		fromAddr, exists := txData["from"].(string)
		require.True(t, exists, "Transaction should have from field")
		require.Equal(t, strings.ToLower(operations.DefaultRichAddress), strings.ToLower(fromAddr), "From address should match")
	})

	t.Run("EthGetTransactionReceipt", func(t *testing.T) {
		// Get receipt using operations RPC method
		result, err := operations.EthGetTransactionReceipt(common.HexToHash(txhash))
		require.NoError(t, err)

		receiptData, _ := result.(map[string]interface{})

		fromAddrStr, exists := receiptData["from"].(string)
		require.True(t, exists, "Receipt should have from field")
		require.Equal(t, strings.ToLower(operations.DefaultRichAddress), strings.ToLower(fromAddrStr), "from address should match sender")

		statusStr, exists := receiptData["status"].(string)
		require.True(t, exists, "Receipt should have status field")
		require.Equal(t, "0x1", statusStr, "status should be 0x1 for successful transaction")

		toAddrStr, exists := receiptData["to"].(string)
		require.True(t, exists, "Receipt should have to field")
		require.Equal(t, strings.ToLower(operations.DefaultRichAddress), strings.ToLower(toAddrStr), "to address should match recipient")

		txHashStr, exists := receiptData["transactionHash"].(string)
		require.True(t, exists, "Receipt should have transactionHash field")
		require.Equal(t, txhash, txHashStr, "transactionHash should match the original transaction hash")
	})
}

// TestEthereumLogsRPC tests Ethereum logs-related RPC methods
func TestEthereumLogsRPC(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}

	_, blockNumber := SetupTestEnvironment(t)

	// Test eth_getLogs
	t.Run("EthGetLogs", func(t *testing.T) {
		fromBlock := fmt.Sprintf("0x%x", blockNumber)
		toBlock := fmt.Sprintf("0x%x", blockNumber)
		address := common.HexToAddress("0x1234567890123456789012345678901234567890")

		logs, err := operations.EthGetLogs(fromBlock, toBlock, address)
		require.NoError(t, err)
		require.NotNil(t, logs, "Logs should not be nil")
		log.Info("EthGetLogs result type: %T", logs)
	})
}

// TestTxPoolRPC tests transaction pool related RPC methods
func TestTxPoolRPC(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}

	_, _ = SetupTestEnvironment(t)

	// Test txpool_content - This might return a large object, so only log type
	t.Run("TxPoolContent", func(t *testing.T) {
		content, err := operations.TxPoolContent()
		require.NoError(t, err)
		log.Info("TxPoolContent result type: %T", content)
	})

	// Test txpool_status
	t.Run("TxPoolStatus", func(t *testing.T) {
		status, err := operations.TxPoolStatus()
		require.NoError(t, err)
		log.Info("TxPoolStatus result type: %T", status)
	})
}

func TestNewTransactionTypes(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}

	ctx := context.Background()
	client, err := ethclient.Dial(operations.DefaultL2NetworkURL)
	require.NoError(t, err)
	defer client.Close()

	EnsureContractsDeployed(t)

	chainID, err := client.ChainID(ctx)
	require.NoError(t, err)

	privateKey, err := crypto.HexToECDSA(TmpSenderPrivateKey)
	require.NoError(t, err)
	fromAddress := crypto.PubkeyToAddress(privateKey.PublicKey)
	toAddress := common.HexToAddress("0x1111111111111111111111111111111111111111")

	fundingAmount := uint256.NewInt(10000000000000000000)
	fundingTxHash := TransToken(t, ctx, client, fundingAmount, fromAddress.String())
	t.Logf("Funded test address %s with 10 ETH, tx: %s", fromAddress.Hex(), fundingTxHash)

	t.Run("EIP1559Transactions", func(t *testing.T) {
		t.Run("SimpleTransferWithMaxFeePerGas", func(t *testing.T) {
			nonce, err := client.PendingNonceAt(ctx, fromAddress)
			require.NoError(t, err)

			value := big.NewInt(1000000000000000000)
			gasLimit := uint64(21000)
			maxFeePerGas := big.NewInt(20000000000)
			maxPriorityFeePerGas := big.NewInt(1000000000)

			tx := types.NewTx(&types.DynamicFeeTx{
				ChainID:   chainID,
				Nonce:     nonce,
				GasTipCap: maxPriorityFeePerGas,
				GasFeeCap: maxFeePerGas,
				Gas:       gasLimit,
				To:        &toAddress,
				Value:     value,
				Data:      nil,
			})

			txHash, receipt := SignAndSendTransaction(ctx, t, client, tx, privateKey)

			require.Equal(t, types.ReceiptStatusSuccessful, receipt.Status, "Transaction should succeed")
			require.Equal(t, uint64(21000), receipt.GasUsed, "Should use exactly 21000 gas for simple transfer")
			require.Equal(t, uint8(types.DynamicFeeTxType), receipt.Type, "Receipt type should be DynamicFeeTx")

			t.Logf("EIP-1559 transfer successful: %s, gas used: %d", txHash.Hex(), receipt.GasUsed)
		})

		t.Run("ContractCallWithEIP1559", func(t *testing.T) {
			// Test EIP-1559 transaction calling a smart contract
			nonce, err := client.PendingNonceAt(ctx, fromAddress)
			require.NoError(t, err)

			contractAABI, err := abi.JSON(strings.NewReader(constants.ContractAABIJson))
			require.NoError(t, err)
			calldata, err := contractAABI.Pack("triggerCall")
			require.NoError(t, err)

			gasLimit := uint64(200000)
			maxFeePerGas := big.NewInt(20000000000)
			maxPriorityFeePerGas := big.NewInt(2000000000)

			// Create EIP-1559 contract call transaction
			tx := types.NewTx(&types.DynamicFeeTx{
				ChainID:   chainID,
				Nonce:     nonce,
				GasTipCap: maxPriorityFeePerGas,
				GasFeeCap: maxFeePerGas,
				Gas:       gasLimit,
				To:        &ContractAAddr,
				Value:     big.NewInt(0),
				Data:      calldata,
			})

			txHash, receipt := SignAndSendTransaction(ctx, t, client, tx, privateKey)

			require.Equal(t, types.ReceiptStatusSuccessful, receipt.Status, "Contract call should succeed")
			require.Greater(t, receipt.GasUsed, uint64(21000), "Contract call should use more than 21000 gas")

			t.Logf("EIP-1559 contract call successful: %s, gas used: %d", txHash.Hex(), receipt.GasUsed)
		})

		t.Run("eth_feeHistory", func(t *testing.T) {
			numberOfTransactions := 10
			transErc20TokenBatch(t, ctx, client, ERC20Addr, big.NewInt(Gwei), toAddress.String(), numberOfTransactions)

			// Get fee history for last 20 blocks
			blockCount := uint64(20)
			history, err := client.FeeHistory(ctx, blockCount, nil, nil)
			require.NoError(t, err)

			oldestBlockNum := history.OldestBlock.Uint64()
			t.Logf("Fee history oldest block: %d, blocks returned: %d", oldestBlockNum, blockCount)

			for i := uint64(0); i < blockCount; i++ {
				blockNum := big.NewInt(int64(oldestBlockNum) + int64(i))
				block, err := client.BlockByNumber(ctx, blockNum)
				require.NoError(t, err, "Failed to get block %d", blockNum.Uint64())

				feeHistoryBaseFee := history.BaseFee[i]
				blockHeaderBaseFee := block.BaseFee()
				require.Equal(t, feeHistoryBaseFee, blockHeaderBaseFee, "Base fee should match between fee history and block headers")
			}
		})
	})

	t.Run("EIP2930Transaction", func(t *testing.T) {
		nonce, err := client.PendingNonceAt(ctx, fromAddress)
		require.NoError(t, err)

		gasLimit := uint64(26000)
		gasPrice, err := client.SuggestGasPrice(ctx)
		require.NoError(t, err)

		// Create access list
		accessList := types.AccessList{
			{
				Address: toAddress,
				StorageKeys: []common.Hash{
					common.HexToHash("0x0000000000000000000000000000000000000000000000000000000000000000"),
				},
			},
		}

		tx := types.NewTx(&types.AccessListTx{
			ChainID:    chainID,
			Nonce:      nonce,
			GasPrice:   gasPrice,
			Gas:        gasLimit,
			To:         &toAddress,
			Value:      big.NewInt(0),
			Data:       nil,
			AccessList: accessList,
		})

		txHash, receipt := SignAndSendTransaction(ctx, t, client, tx, privateKey)

		require.Equal(t, types.ReceiptStatusSuccessful, receipt.Status, "EIP-2930 transaction with access list should succeed")
		require.Equal(t, uint8(types.AccessListTxType), receipt.Type, "Receipt type should be AccessListTx")

		t.Logf("EIP-2930 AccessListTx successful: %s, gas used: %d", txHash.Hex(), receipt.GasUsed)
	})

	t.Run("EIP7702Transaction", func(t *testing.T) {
		nonce, err := client.PendingNonceAt(ctx, fromAddress)
		require.NoError(t, err)

		// Create authorization to delegate the fromAddress's code to ContractC
		auth := types.SetCodeAuthorization{
			ChainID: *uint256.MustFromBig(chainID),
			Address: ContractCAddr,
			Nonce:   nonce,
		}

		signedAuth, err := types.SignSetCode(privateKey, auth)
		require.NoError(t, err)

		authority, err := signedAuth.Authority()
		require.NoError(t, err)
		require.Equal(t, fromAddress, authority, "Authority should match the signing address")

		gasLimit := uint64(100000)
		maxFeePerGas := big.NewInt(20000000000)
		maxPriorityFeePerGas := big.NewInt(1000000000)

		// Set the fromAddress to delegate to ContractC's code
		tx := types.NewTx(&types.SetCodeTx{
			ChainID:   uint256.MustFromBig(chainID),
			Nonce:     nonce,
			GasTipCap: uint256.MustFromBig(maxPriorityFeePerGas),
			GasFeeCap: uint256.MustFromBig(maxFeePerGas),
			Gas:       gasLimit,
			To:        toAddress,
			Value:     uint256.NewInt(0),
			Data:      nil,
			AuthList:  []types.SetCodeAuthorization{signedAuth},
		})

		require.Equal(t, uint8(types.SetCodeTxType), tx.Type(), "Transaction type should be SetCodeTx")

		authList := tx.SetCodeAuthorizations()
		require.NotNil(t, authList, "Authorization list should not be nil")
		require.Len(t, authList, 1, "Should have exactly 1 authorization")
		require.Equal(t, ContractCAddr, authList[0].Address, "Authorization should delegate to ContractC")

		txHash, receipt := SignAndSendTransaction(ctx, t, client, tx, privateKey)

		require.Equal(t, types.ReceiptStatusSuccessful, receipt.Status, "EIP-7702 transaction should succeed")
		require.Equal(t, uint8(types.SetCodeTxType), receipt.Type, "Receipt type should be SetCodeTx")
		require.Greater(t, receipt.GasUsed, uint64(21000), "Should use more than 21000 gas due to authorization processing")

		minedTx, _, err := client.TransactionByHash(ctx, txHash)
		require.NoError(t, err)

		txSigner := types.MakeSigner(operations.GetTestChainConfig(operations.DefaultL2ChainID), big.NewInt(1), 0)
		txFromAddress, err := types.Sender(txSigner, minedTx)
		require.NoError(t, err)
		require.Equal(t, fromAddress, txFromAddress, "Transaction from address should match the EOA address")
		require.Equal(t, toAddress, *minedTx.To(), "Transaction to address should match the recipient address")

		t.Logf("EIP-7702 transaction mined successfully in block %d, gas used: %d", receipt.BlockNumber.Uint64(), receipt.GasUsed)
	})

	t.Run("EIP3198Transaction", func(t *testing.T) {
		// BASEFEE (0x48) + STOP (0x00)
		var result hexutil.Bytes

		err := client.Client().CallContext(ctx, &result, "eth_call", map[string]interface{}{
			"to":   nil,      // Contract creation context
			"data": "0x4800", // BASEFEE + STOP
		}, "latest")
		require.NoError(t, err, "BASEFEE opcode should execute without error (EIP-3198 is supported)")

		latestBlock, err := client.BlockByNumber(ctx, nil)
		require.NoError(t, err)
		require.NotNil(t, latestBlock, "Block should not be nil")
		require.NotNil(t, latestBlock.BaseFee(), "Block should have a base fee field (EIP-3198)")

		t.Logf("Current block %d base fee: %s wei", latestBlock.Number().Uint64(), latestBlock.BaseFee().String())
	})

	t.Run("EIP3529Transaction", func(t *testing.T) {
		// Constructor bytecode: CALLER (0x33), SELFDESTRUCT (0xff)
		// This will self-destruct immediately during deployment, sending any value to the caller
		deployBytecode := common.Hex2Bytes("33ff")

		nonce, err := client.PendingNonceAt(ctx, fromAddress)
		require.NoError(t, err)

		gasPrice, err := client.SuggestGasPrice(ctx)
		require.NoError(t, err)

		deployTx := types.NewContractCreation(nonce, big.NewInt(0), 100000, gasPrice, deployBytecode)

		txHash, deployReceipt := SignAndSendTransaction(ctx, t, client, deployTx, privateKey)

		contractAddress := deployReceipt.ContractAddress
		t.Logf("Contract address (self-destructed): %s, tx hash: %s", contractAddress.Hex(), txHash.Hex())

		// Use debug_traceTransaction to get the refund counter
		var traceResult map[string]interface{}
		err = client.Client().CallContext(ctx, &traceResult, "debug_traceTransaction", txHash, map[string]interface{}{})
		require.NoError(t, err)

		refundCounter := GetRefundCounterFromTrace(traceResult, "SELFDESTRUCT")
		t.Logf("Refund counter after SELFDESTRUCT: %d", refundCounter)

		require.Equal(t, uint64(0), refundCounter, "SELFDESTRUCT refund should be 0 with EIP-3529")

		codeAfter, err := client.CodeAt(ctx, contractAddress, deployReceipt.BlockNumber)
		require.NoError(t, err)
		require.Empty(t, codeAfter, "Contract should have no code after SELFDESTRUCT")
	})

	t.Run("EIP4844Transactions", func(t *testing.T) {
		// OP Stack disables EIP-4844 blob transactions on Layer 2
		// So we check if blob fields are present in block data
		result, err := operations.EthGetBlockByNumber("latest", true)
		require.NoError(t, err)

		blockdata, _ := result.(map[string]interface{})
		require.NotNil(t, blockdata, "Block data should not be nil")

		blockGasUsed, exists := blockdata["blobGasUsed"].(string)
		require.True(t, exists, "Block should have blockGasUsed field")

		excessBlobGas, exists := blockdata["excessBlobGas"].(string)
		require.True(t, exists, "Block should have excessBlobGas field")

		t.Logf("Block gas used: %s", blockGasUsed)
		t.Logf("Block excess blob gas: %s", excessBlobGas)
	})
}

func waitForReceipt(t *testing.T, ctx context.Context, client *ethclient.Client, txHash common.Hash, timeout time.Duration) *types.Receipt {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		receipt, err := client.TransactionReceipt(ctx, txHash)
		if err == nil && receipt != nil {
			t.Logf("Transaction %s mined in block %d", txHash.Hex(), receipt.BlockNumber.Uint64())
			return receipt
		}
		time.Sleep(2 * time.Second)
	}
	t.Fatalf("Transaction %s was not mined within timeout", txHash.Hex())
	return nil
}

func verifyTransactionPriority(t *testing.T, ctx context.Context, client *ethclient.Client,
	prioReceipt, normalReceipt *types.Receipt, prioHash, normalHash common.Hash, name1, name2 string) {
	require.LessOrEqual(t, prioReceipt.BlockNumber.Uint64(), normalReceipt.BlockNumber.Uint64(),
		"%s tx should be in same or earlier block than %s tx", name1, name2)

	if prioReceipt.BlockNumber.Uint64() == normalReceipt.BlockNumber.Uint64() {
		block, err := client.BlockByNumber(ctx, prioReceipt.BlockNumber)
		require.NoError(t, err)

		var prioIndex, normalIndex int = -1, -1
		for i, tx := range block.Transactions() {
			if tx.Hash() == prioHash {
				prioIndex = i
			}
			if tx.Hash() == normalHash {
				normalIndex = i
			}
		}

		require.NotEqual(t, -1, prioIndex, "%s transaction not found in block", name1)
		require.NotEqual(t, -1, normalIndex, "%s transaction not found in block", name2)
		require.Less(t, prioIndex, normalIndex, "%s tx (index %d) should come before %s tx (index %d) in block %d",
			name1, prioIndex, name2, normalIndex, block.NumberU64())

		t.Logf("Priority verified: %s[%d] < %s[%d] in block %d", name1, prioIndex, name2, normalIndex, block.NumberU64())
	}
}
