// Package l1 implements L1 (Ethereum) client for DEMO.
package l1

import (
	"context"
	"crypto/ecdsa"
	"fmt"
	"log"
	"math/big"
	"strings"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"

	"github.com/ethereum-optimism/optimism/demo/core/state"
	"github.com/ethereum-optimism/optimism/demo/core/types"
)

// Contract ABIs
const batchInboxABI = `[
	{"inputs":[{"name":"batchIndex","type":"uint256"},{"name":"txDataHash","type":"bytes32"}],"name":"submitBatchData","outputs":[],"stateMutability":"nonpayable","type":"function"},
	{"inputs":[],"name":"nextBatchIndex","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"}
]`

const outputOracleABI = `[
	{"inputs":[{"name":"stateHash","type":"bytes32"},{"name":"mptRoot","type":"bytes32"},{"name":"l2BlockNumber","type":"uint256"}],"name":"proposeOutput","outputs":[],"stateMutability":"nonpayable","type":"function"},
	{"inputs":[],"name":"nextOutputIndex","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
	{"inputs":[{"name":"batchIndex","type":"uint256"}],"name":"getOutput","outputs":[{"components":[{"name":"stateHash","type":"bytes32"},{"name":"mptRoot","type":"bytes32"},{"name":"timestamp","type":"uint128"},{"name":"l2BlockNumber","type":"uint128"}],"name":"","type":"tuple"}],"stateMutability":"view","type":"function"},
	{"inputs":[{"name":"batchIndex","type":"uint256"}],"name":"getMPTRoot","outputs":[{"type":"bytes32"}],"stateMutability":"view","type":"function"}
]`

const disputeGameFactoryABI = `[
	{"inputs":[{"name":"_batchIndex","type":"uint256"},{"name":"_rootClaim","type":"bytes32"}],"name":"createGame","outputs":[{"name":"gameAddr","type":"address"}],"stateMutability":"payable","type":"function"},
	{"inputs":[],"name":"gameCount","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
	{"inputs":[{"name":"_batchIndex","type":"uint256"}],"name":"hasActiveDispute","outputs":[{"type":"bool"}],"stateMutability":"view","type":"function"},
	{"inputs":[{"name":"_batchIndex","type":"uint256"}],"name":"getActiveGame","outputs":[{"type":"address"}],"stateMutability":"view","type":"function"}
]`

const disputeGameABI = `[
	{"inputs":[{"name":"parentIndex","type":"uint256"},{"name":"claim","type":"bytes32"}],"name":"attack","outputs":[],"stateMutability":"payable","type":"function"},
	{"inputs":[{"name":"parentIndex","type":"uint256"},{"name":"claim","type":"bytes32"}],"name":"defend","outputs":[],"stateMutability":"payable","type":"function"},
	{"inputs":[{"name":"_claimIndex","type":"uint256"},{"name":"_stateData","type":"bytes"},{"name":"_proof","type":"bytes"},{"name":"_claimedPostState","type":"bytes32"}],"name":"step","outputs":[],"stateMutability":"nonpayable","type":"function"},
	{"inputs":[],"name":"resolve","outputs":[],"stateMutability":"nonpayable","type":"function"},
	{"inputs":[],"name":"status","outputs":[{"type":"uint8"}],"stateMutability":"view","type":"function"},
	{"inputs":[],"name":"claimCount","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
	{"inputs":[{"name":"index","type":"uint256"}],"name":"getClaim","outputs":[{"components":[{"name":"parentIndex","type":"uint32"},{"name":"counteredBy","type":"address"},{"name":"claimant","type":"address"},{"name":"bond","type":"uint128"},{"name":"claim","type":"bytes32"},{"name":"position","type":"uint128"},{"name":"clock","type":"uint128"}],"name":"","type":"tuple"}],"stateMutability":"view","type":"function"},
	{"inputs":[],"name":"canResolve","outputs":[{"type":"bool"}],"stateMutability":"view","type":"function"}
]`

// Config holds L1 client configuration.
type Config struct {
	RPCURL                    string
	ChainID                   *big.Int
	PrivateKey                *ecdsa.PrivateKey
	BatchInboxAddress         types.Address
	OutputOracleAddress       types.Address
	DisputeGameFactoryAddress types.Address
	PreimageOracleAddress     types.Address
	MIPSAddress               types.Address
}

// Client provides L1 interaction capabilities.
type Client struct {
	config    *Config
	ethClient *ethclient.Client

	batcherKey     *ecdsa.PrivateKey
	proposerKey    *ecdsa.PrivateKey
	challengerKey  *ecdsa.PrivateKey
	batcherAddr    common.Address
	proposerAddr   common.Address
	challengerAddr common.Address

	batchInboxABI         abi.ABI
	outputOracleABI       abi.ABI
	disputeGameFactoryABI abi.ABI
	disputeGameABI        abi.ABI

	// Track submitted indices
	mu sync.Mutex
}

// NewClient creates a new L1 client.
func NewClient(config *Config) (*Client, error) {
	if config.RPCURL == "" {
		return nil, fmt.Errorf("L1 RPC URL is required")
	}

	// Connect to L1
	ethClient, err := ethclient.Dial(config.RPCURL)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to L1: %w", err)
	}

	// Parse ABIs
	batchABI, err := abi.JSON(strings.NewReader(batchInboxABI))
	if err != nil {
		return nil, fmt.Errorf("failed to parse BatchInbox ABI: %w", err)
	}

	outputABI, err := abi.JSON(strings.NewReader(outputOracleABI))
	if err != nil {
		return nil, fmt.Errorf("failed to parse OutputOracle ABI: %w", err)
	}

	factoryABI, err := abi.JSON(strings.NewReader(disputeGameFactoryABI))
	if err != nil {
		return nil, fmt.Errorf("failed to parse DisputeGameFactory ABI: %w", err)
	}

	gameABI, err := abi.JSON(strings.NewReader(disputeGameABI))
	if err != nil {
		return nil, fmt.Errorf("failed to parse DisputeGame ABI: %w", err)
	}

	// Anvil account 1 (batcher): 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
	batcherKey, _ := crypto.HexToECDSA("59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d")
	// Anvil account 2 (proposer): 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
	proposerKey, _ := crypto.HexToECDSA("5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a")
	// Anvil account 3 (challenger): 0x90F79bf6EB2c4f870365E785982E1f101E93b906
	challengerKey, _ := crypto.HexToECDSA("7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6")

	return &Client{
		config:                config,
		ethClient:             ethClient,
		batcherKey:            batcherKey,
		proposerKey:           proposerKey,
		challengerKey:         challengerKey,
		batcherAddr:           crypto.PubkeyToAddress(batcherKey.PublicKey),
		proposerAddr:          crypto.PubkeyToAddress(proposerKey.PublicKey),
		challengerAddr:        crypto.PubkeyToAddress(challengerKey.PublicKey),
		batchInboxABI:         batchABI,
		outputOracleABI:       outputABI,
		disputeGameFactoryABI: factoryABI,
		disputeGameABI:        gameABI,
	}, nil
}

// getNextBatchIndex gets the next batch index from L1 contract.
func (c *Client) getNextBatchIndex(ctx context.Context) (uint64, error) {
	callData, err := c.batchInboxABI.Pack("nextBatchIndex")
	if err != nil {
		return 0, err
	}

	toAddr := common.Address(c.config.BatchInboxAddress)
	result, err := c.ethClient.CallContract(ctx, ethereum.CallMsg{
		To:   &toAddr,
		Data: callData,
	}, nil)
	if err != nil {
		return 0, err
	}

	var index *big.Int
	err = c.batchInboxABI.UnpackIntoInterface(&index, "nextBatchIndex", result)
	if err != nil {
		return 0, err
	}

	return index.Uint64(), nil
}

// SubmitBatchData submits batch transaction data to DEMOBatchInbox contract.
func (c *Client) SubmitBatchData(ctx context.Context, batchIndex uint64, txDataHash types.Hash, data []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	// Get the expected batch index from L1
	l1BatchIndex, err := c.getNextBatchIndex(ctx)
	if err != nil {
		log.Printf("[L1Client] Failed to get nextBatchIndex: %v", err)
		return err
	}

	log.Printf("[L1Client] Submitting batch to BatchInbox (L1 index=%d, DEMO index=%d)...", l1BatchIndex, batchIndex)

	// Encode function call with L1's expected index
	callData, err := c.batchInboxABI.Pack("submitBatchData", big.NewInt(int64(l1BatchIndex)), [32]byte(txDataHash))
	if err != nil {
		return fmt.Errorf("failed to encode submitBatchData: %w", err)
	}

	// Send transaction with batcher key
	toAddr := common.Address(c.config.BatchInboxAddress)
	txHash, err := c.sendTransaction(ctx, c.batcherKey, c.batcherAddr, &toAddr, callData)
	if err != nil {
		return fmt.Errorf("failed to submit batch data: %w", err)
	}

	log.Printf("[L1Client] ✓ Batch submitted to L1 (tx: %s)", txHash.Hex()[:18])
	return nil
}

// SubmitOutput submits state commitment to DEMOOutputOracle contract.
func (c *Client) SubmitOutput(ctx context.Context, output *state.Output) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	// Ensure stateHash and mptRoot are not zero (contract requirement)
	stateHash := output.FinalStateHash
	mptRoot := output.MPTRoot

	// If zero, use a placeholder (in production, this should never happen)
	if stateHash == (types.Hash{}) {
		stateHash = types.Keccak256([]byte(fmt.Sprintf("state-%d", output.BatchIndex)))
	}
	if mptRoot == (types.Hash{}) {
		mptRoot = types.Keccak256([]byte(fmt.Sprintf("mpt-%d", output.BatchIndex)))
	}

	// Use a placeholder L2 block number (endBlock of batch)
	l2BlockNumber := (output.BatchIndex + 1) * 10 // Assuming 10 blocks per batch

	log.Printf("[L1Client] Submitting output to OutputOracle (stateHash=%x, mptRoot=%x, l2Block=%d)...",
		stateHash[:8], mptRoot[:8], l2BlockNumber)

	// Encode function call: proposeOutput(bytes32 stateHash, bytes32 mptRoot, uint256 l2BlockNumber)
	callData, err := c.outputOracleABI.Pack("proposeOutput",
		[32]byte(stateHash),
		[32]byte(mptRoot),
		big.NewInt(int64(l2BlockNumber)),
	)
	if err != nil {
		return fmt.Errorf("failed to encode proposeOutput: %w", err)
	}

	// Send transaction with proposer key
	toAddr := common.Address(c.config.OutputOracleAddress)
	txHash, err := c.sendTransaction(ctx, c.proposerKey, c.proposerAddr, &toAddr, callData)
	if err != nil {
		return fmt.Errorf("failed to submit output: %w", err)
	}

	log.Printf("[L1Client] ✓ Output submitted to L1 (tx: %s)", txHash.Hex()[:18])
	return nil
}

// sendTransaction sends a transaction to L1.
func (c *Client) sendTransaction(ctx context.Context, privateKey *ecdsa.PrivateKey, from common.Address, to *common.Address, data []byte) (common.Hash, error) {
	// Get nonce
	nonce, err := c.ethClient.PendingNonceAt(ctx, from)
	if err != nil {
		return common.Hash{}, fmt.Errorf("failed to get nonce: %w", err)
	}

	// Get gas price
	gasPrice, err := c.ethClient.SuggestGasPrice(ctx)
	if err != nil {
		return common.Hash{}, fmt.Errorf("failed to get gas price: %w", err)
	}

	// Estimate gas
	msg := ethereum.CallMsg{
		From: from,
		To:   to,
		Data: data,
	}
	gasLimit, err := c.ethClient.EstimateGas(ctx, msg)
	if err != nil {
		// Use default gas limit if estimation fails
		gasLimit = 200000
		log.Printf("[L1Client] Gas estimation failed: %v, using default: %d", err, gasLimit)
	}

	// Get chain ID
	chainID := c.config.ChainID
	if chainID == nil {
		chainID, err = c.ethClient.ChainID(ctx)
		if err != nil {
			return common.Hash{}, fmt.Errorf("failed to get chain ID: %w", err)
		}
	}

	// Create transaction
	tx := ethtypes.NewTransaction(nonce, *to, big.NewInt(0), gasLimit, gasPrice, data)

	// Sign transaction
	signedTx, err := ethtypes.SignTx(tx, ethtypes.NewEIP155Signer(chainID), privateKey)
	if err != nil {
		return common.Hash{}, fmt.Errorf("failed to sign transaction: %w", err)
	}

	// Send transaction
	if err := c.ethClient.SendTransaction(ctx, signedTx); err != nil {
		return common.Hash{}, fmt.Errorf("failed to send transaction: %w", err)
	}

	return signedTx.Hash(), nil
}

// GetLatestOutputIndex returns the latest output index from L1.
func (c *Client) GetLatestOutputIndex() (uint64, error) {
	ctx := context.Background()
	callData, err := c.outputOracleABI.Pack("nextOutputIndex")
	if err != nil {
		return 0, err
	}

	toAddr := common.Address(c.config.OutputOracleAddress)
	result, err := c.ethClient.CallContract(ctx, ethereum.CallMsg{
		To:   &toAddr,
		Data: callData,
	}, nil)
	if err != nil {
		return 0, err
	}

	var index *big.Int
	err = c.outputOracleABI.UnpackIntoInterface(&index, "nextOutputIndex", result)
	if err != nil {
		return 0, err
	}

	return index.Uint64(), nil
}

// GetOutputMPTRoot gets the MPT root for a batch from L1.
func (c *Client) GetOutputMPTRoot(ctx context.Context, batchIndex uint64) (types.Hash, error) {
	callData, err := c.outputOracleABI.Pack("getMPTRoot", big.NewInt(int64(batchIndex)))
	if err != nil {
		return types.Hash{}, err
	}

	toAddr := common.Address(c.config.OutputOracleAddress)
	result, err := c.ethClient.CallContract(ctx, ethereum.CallMsg{
		To:   &toAddr,
		Data: callData,
	}, nil)
	if err != nil {
		return types.Hash{}, err
	}

	var root [32]byte
	err = c.outputOracleABI.UnpackIntoInterface(&root, "getMPTRoot", result)
	if err != nil {
		return types.Hash{}, err
	}

	return types.Hash(root), nil
}

// HasActiveDispute checks if a batch has an active dispute.
func (c *Client) HasActiveDispute(ctx context.Context, batchIndex uint64) (bool, error) {
	callData, err := c.disputeGameFactoryABI.Pack("hasActiveDispute", big.NewInt(int64(batchIndex)))
	if err != nil {
		return false, err
	}

	toAddr := common.Address(c.config.DisputeGameFactoryAddress)
	result, err := c.ethClient.CallContract(ctx, ethereum.CallMsg{
		To:   &toAddr,
		Data: callData,
	}, nil)
	if err != nil {
		return false, err
	}

	var hasDispute bool
	err = c.disputeGameFactoryABI.UnpackIntoInterface(&hasDispute, "hasActiveDispute", result)
	if err != nil {
		return false, err
	}

	return hasDispute, nil
}

// CreateDisputeGame creates a new dispute game on L1.
func (c *Client) CreateDisputeGame(ctx context.Context, batchIndex uint64, claimedRoot types.Hash) (common.Address, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	log.Printf("[L1Client] Creating dispute game for batch %d (claimed root: %x)...", batchIndex, claimedRoot[:8])

	// Encode function call: createGame(uint256 _batchIndex, bytes32 _rootClaim)
	callData, err := c.disputeGameFactoryABI.Pack("createGame",
		big.NewInt(int64(batchIndex)),
		[32]byte(claimedRoot),
	)
	if err != nil {
		return common.Address{}, fmt.Errorf("failed to encode createGame: %w", err)
	}

	// Send transaction with challenger key and bond (0.1 ETH)
	toAddr := common.Address(c.config.DisputeGameFactoryAddress)
	txHash, err := c.sendTransactionWithValue(ctx, c.challengerKey, c.challengerAddr, &toAddr, callData, big.NewInt(100000000000000000)) // 0.1 ETH
	if err != nil {
		return common.Address{}, fmt.Errorf("failed to create dispute game: %w", err)
	}

	log.Printf("[L1Client] ✓ Dispute game created (tx: %s)", txHash.Hex()[:18])

	// Wait for transaction to be mined (poll for receipt)
	var receipt *ethtypes.Receipt
	for i := 0; i < 10; i++ {
		receipt, err = c.ethClient.TransactionReceipt(ctx, txHash)
		if err == nil && receipt != nil {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if receipt == nil || receipt.Status != 1 {
		return common.Address{}, fmt.Errorf("transaction failed or not mined")
	}

	// Get the game address from the factory
	gameAddr, err := c.getActiveGameAddress(ctx, batchIndex)
	if err != nil {
		return common.Address{}, err
	}

	log.Printf("[L1Client] Dispute game address: %s", gameAddr.Hex())
	return gameAddr, nil
}

// getActiveGameAddress gets the active game address for a batch.
func (c *Client) getActiveGameAddress(ctx context.Context, batchIndex uint64) (common.Address, error) {
	callData, err := c.disputeGameFactoryABI.Pack("getActiveGame", big.NewInt(int64(batchIndex)))
	if err != nil {
		return common.Address{}, err
	}

	toAddr := common.Address(c.config.DisputeGameFactoryAddress)
	result, err := c.ethClient.CallContract(ctx, ethereum.CallMsg{
		To:   &toAddr,
		Data: callData,
	}, nil)
	if err != nil {
		return common.Address{}, err
	}

	var gameAddr common.Address
	err = c.disputeGameFactoryABI.UnpackIntoInterface(&gameAddr, "getActiveGame", result)
	if err != nil {
		return common.Address{}, err
	}

	return gameAddr, nil
}

// GetDisputeGame returns a dispute game by address.
func (c *Client) GetDisputeGame(ctx context.Context, gameAddr common.Address) (*DisputeGame, error) {
	// Get status
	callData, err := c.disputeGameABI.Pack("status")
	if err != nil {
		return nil, err
	}

	result, err := c.ethClient.CallContract(ctx, ethereum.CallMsg{
		To:   &gameAddr,
		Data: callData,
	}, nil)
	if err != nil {
		return nil, err
	}

	var status uint8
	err = c.disputeGameABI.UnpackIntoInterface(&status, "status", result)
	if err != nil {
		return nil, err
	}

	return &DisputeGame{
		GameAddress: types.Address(gameAddr),
		Status:      status,
	}, nil
}

// GetActiveGames returns all active dispute games.
func (c *Client) GetActiveGames(ctx context.Context) ([]*DisputeGame, error) {
	// In a full implementation, this would iterate through the factory
	return nil, nil
}

// Attack submits an attack move in a dispute game.
func (c *Client) Attack(ctx context.Context, gameAddr common.Address, parentIndex uint64, claim types.Hash) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	log.Printf("[L1Client] Attack: game=%s parentIndex=%d claim=%x", gameAddr.Hex()[:10], parentIndex, claim[:8])

	callData, err := c.disputeGameABI.Pack("attack",
		big.NewInt(int64(parentIndex)),
		[32]byte(claim),
	)
	if err != nil {
		return fmt.Errorf("failed to encode attack: %w", err)
	}

	// Send with bond (0.01 ETH)
	txHash, err := c.sendTransactionWithValue(ctx, c.challengerKey, c.challengerAddr, &gameAddr, callData, big.NewInt(10000000000000000))
	if err != nil {
		return fmt.Errorf("failed to attack: %w", err)
	}

	log.Printf("[L1Client] ✓ Attack submitted (tx: %s)", txHash.Hex()[:18])
	return nil
}

// Defend submits a defend move in a dispute game.
func (c *Client) Defend(ctx context.Context, gameAddr common.Address, parentIndex uint64, claim types.Hash) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	log.Printf("[L1Client] Defend: game=%s parentIndex=%d claim=%x", gameAddr.Hex()[:10], parentIndex, claim[:8])

	callData, err := c.disputeGameABI.Pack("defend",
		big.NewInt(int64(parentIndex)),
		[32]byte(claim),
	)
	if err != nil {
		return fmt.Errorf("failed to encode defend: %w", err)
	}

	// Send with bond (0.01 ETH)
	txHash, err := c.sendTransactionWithValue(ctx, c.proposerKey, c.proposerAddr, &gameAddr, callData, big.NewInt(10000000000000000))
	if err != nil {
		return fmt.Errorf("failed to defend: %w", err)
	}

	log.Printf("[L1Client] ✓ Defend submitted (tx: %s)", txHash.Hex()[:18])
	return nil
}

// Step executes a single instruction step in a dispute game.
// The preStateHash is logged but not passed to contract - it's derived from parent claim internally.
func (c *Client) Step(ctx context.Context, gameAddr common.Address, claimIndex uint64, stateData, proof []byte, preStateHash, postStateHash common.Hash) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	log.Printf("[L1Client] Step: game=%s claimIndex=%d preState=%s postState=%s",
		gameAddr.Hex()[:10], claimIndex, preStateHash.Hex()[:10], postStateHash.Hex()[:10])

	// DisputeGame.step only takes 4 params: (claimIndex, stateData, proof, claimedPostState)
	// The preStateHash is derived internally from the parent claim
	callData, err := c.disputeGameABI.Pack("step",
		big.NewInt(int64(claimIndex)),
		stateData,
		proof,
		postStateHash,
	)
	if err != nil {
		return fmt.Errorf("failed to encode step: %w", err)
	}

	txHash, err := c.sendTransaction(ctx, c.challengerKey, c.challengerAddr, &gameAddr, callData)
	if err != nil {
		return fmt.Errorf("failed to step: %w", err)
	}

	log.Printf("[L1Client] ✓ Step executed (tx: %s)", txHash.Hex()[:18])
	return nil
}

// Resolve resolves a dispute game.
func (c *Client) Resolve(ctx context.Context, gameAddr common.Address) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	log.Printf("[L1Client] Resolve: game=%s", gameAddr.Hex()[:10])

	callData, err := c.disputeGameABI.Pack("resolve")
	if err != nil {
		return fmt.Errorf("failed to encode resolve: %w", err)
	}

	txHash, err := c.sendTransaction(ctx, c.challengerKey, c.challengerAddr, &gameAddr, callData)
	if err != nil {
		return fmt.Errorf("failed to resolve: %w", err)
	}

	log.Printf("[L1Client] ✓ Game resolved (tx: %s)", txHash.Hex()[:18])
	return nil
}

// CanResolve checks if a game can be resolved.
func (c *Client) CanResolve(ctx context.Context, gameAddr common.Address) (bool, error) {
	callData, err := c.disputeGameABI.Pack("canResolve")
	if err != nil {
		return false, err
	}

	result, err := c.ethClient.CallContract(ctx, ethereum.CallMsg{
		To:   &gameAddr,
		Data: callData,
	}, nil)
	if err != nil {
		return false, err
	}

	var canResolve bool
	err = c.disputeGameABI.UnpackIntoInterface(&canResolve, "canResolve", result)
	if err != nil {
		return false, err
	}

	return canResolve, nil
}

// GetClaimCount gets the number of claims in a game.
func (c *Client) GetClaimCount(ctx context.Context, gameAddr common.Address) (uint64, error) {
	callData, err := c.disputeGameABI.Pack("claimCount")
	if err != nil {
		return 0, err
	}

	result, err := c.ethClient.CallContract(ctx, ethereum.CallMsg{
		To:   &gameAddr,
		Data: callData,
	}, nil)
	if err != nil {
		return 0, err
	}

	var count *big.Int
	err = c.disputeGameABI.UnpackIntoInterface(&count, "claimCount", result)
	if err != nil {
		return 0, err
	}

	return count.Uint64(), nil
}

// sendTransactionWithValue sends a transaction with ETH value.
func (c *Client) sendTransactionWithValue(ctx context.Context, privateKey *ecdsa.PrivateKey, from common.Address, to *common.Address, data []byte, value *big.Int) (common.Hash, error) {
	// Get nonce
	nonce, err := c.ethClient.PendingNonceAt(ctx, from)
	if err != nil {
		return common.Hash{}, fmt.Errorf("failed to get nonce: %w", err)
	}

	// Get gas price
	gasPrice, err := c.ethClient.SuggestGasPrice(ctx)
	if err != nil {
		return common.Hash{}, fmt.Errorf("failed to get gas price: %w", err)
	}

	// Use higher gas limit for contract creation (createGame deploys a new contract)
	gasLimit := uint64(3000000)

	// Get chain ID
	chainID := c.config.ChainID
	if chainID == nil {
		chainID, err = c.ethClient.ChainID(ctx)
		if err != nil {
			return common.Hash{}, fmt.Errorf("failed to get chain ID: %w", err)
		}
	}

	// Create transaction with value
	tx := ethtypes.NewTransaction(nonce, *to, value, gasLimit, gasPrice, data)

	// Sign transaction
	signedTx, err := ethtypes.SignTx(tx, ethtypes.NewEIP155Signer(chainID), privateKey)
	if err != nil {
		return common.Hash{}, fmt.Errorf("failed to sign transaction: %w", err)
	}

	// Send transaction
	if err := c.ethClient.SendTransaction(ctx, signedTx); err != nil {
		return common.Hash{}, fmt.Errorf("failed to send transaction: %w", err)
	}

	return signedTx.Hash(), nil
}

// DisputeGame represents a dispute game.
type DisputeGame struct {
	GameAddress types.Address
	GameID      types.Hash
	BatchIndex  uint64
	ClaimedRoot types.Hash
	Status      uint8 // 0=IN_PROGRESS, 1=CHALLENGER_WINS, 2=DEFENDER_WINS
	Challenger  types.Address
	StartTime   uint64
}

// DisputeGameStatus constants
const (
	GameStatusInProgress    uint8 = 0
	GameStatusChallengerWon uint8 = 1
	GameStatusDefenderWon   uint8 = 2
)

// ParseAddress parses a hex address string.
func ParseAddress(s string) types.Address {
	var addr types.Address
	s = strings.TrimPrefix(s, "0x")
	if len(s) > 40 {
		s = s[len(s)-40:]
	}
	for i := 0; i < len(s)/2 && i < 20; i++ {
		fmt.Sscanf(s[i*2:i*2+2], "%02x", &addr[20-len(s)/2+i])
	}
	return addr
}
