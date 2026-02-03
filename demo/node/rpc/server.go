// Package rpc implements the JSON-RPC API for DEMO node.
package rpc

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"sync"

	"github.com/ethereum-optimism/optimism/demo/core/block"
	"github.com/ethereum-optimism/optimism/demo/core/state"
	"github.com/ethereum-optimism/optimism/demo/core/tx"
	"github.com/ethereum-optimism/optimism/demo/core/types"
)

// RPCRequest represents a JSON-RPC request.
type RPCRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
	ID      interface{}     `json:"id"`
}

// RPCResponse represents a JSON-RPC response.
type RPCResponse struct {
	JSONRPC string      `json:"jsonrpc"`
	Result  interface{} `json:"result,omitempty"`
	Error   *RPCError   `json:"error,omitempty"`
	ID      interface{} `json:"id"`
}

// RPCError represents a JSON-RPC error.
type RPCError struct {
	Code    int         `json:"code"`
	Message string      `json:"message"`
	Data    interface{} `json:"data,omitempty"`
}

// Error codes
const (
	ErrCodeParseError     = -32700
	ErrCodeInvalidRequest = -32600
	ErrCodeMethodNotFound = -32601
	ErrCodeInvalidParams  = -32602
	ErrCodeInternalError  = -32603
)

// Backend interface for RPC operations.
type Backend interface {
	// State operations
	GetState() *state.State
	GetBalance(addr types.Address, token types.TokenID) *big.Int
	GetAccount(addr types.Address) *AccountInfo
	GetPool(tokenA, tokenB types.TokenID) *PoolInfo

	// Block operations
	GetLatestBlock() *block.Block
	GetBlockByNumber(num uint64) *block.Block

	// Transaction operations
	SubmitTx(tx *tx.Transaction) error
	GetPendingTxCount() int

	// Batch operations
	GetCurrentBatch() *state.Batch
	GetCompletedBatches(fromIndex uint64) []*state.Batch
	GetBatchByIndex(index uint64) *state.Batch
}

// AccountInfo represents account information for RPC.
type AccountInfo struct {
	Address  string            `json:"address"`
	Nonce    uint64            `json:"nonce"`
	Balances map[string]string `json:"balances"`
}

// PoolInfo represents pool information for RPC.
type PoolInfo struct {
	PoolID   string `json:"poolId"`
	TokenA   string `json:"tokenA"`
	TokenB   string `json:"tokenB"`
	ReserveA string `json:"reserveA"`
	ReserveB string `json:"reserveB"`
	TotalLP  string `json:"totalLp"`
	FeeRate  uint64 `json:"feeRate"`
}

// BlockInfo represents block information for RPC.
type BlockInfo struct {
	Number     uint64   `json:"number"`
	Hash       string   `json:"hash"`
	ParentHash string   `json:"parentHash"`
	StateHash  string   `json:"stateHash"`
	TxRoot     string   `json:"transactionsRoot"`
	Timestamp  uint64   `json:"timestamp"`
	TxCount    int      `json:"transactionCount"`
	TxHashes   []string `json:"transactionHashes,omitempty"`
}

// Server implements the JSON-RPC server.
type Server struct {
	backend Backend
	server  *http.Server
	mux     sync.RWMutex
}

// NewServer creates a new RPC server.
func NewServer(backend Backend) *Server {
	return &Server{
		backend: backend,
	}
}

// Start starts the RPC server.
func (s *Server) Start(addr string) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleRPC)

	s.server = &http.Server{
		Addr:    addr,
		Handler: mux,
	}

	log.Printf("Starting RPC server on %s", addr)
	go func() {
		if err := s.server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("RPC server error: %v", err)
		}
	}()

	return nil
}

// Stop stops the RPC server.
func (s *Server) Stop(ctx context.Context) error {
	if s.server != nil {
		return s.server.Shutdown(ctx)
	}
	return nil
}

// handleRPC handles incoming RPC requests.
func (s *Server) handleRPC(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		s.writeError(w, nil, ErrCodeParseError, "Failed to read request body")
		return
	}

	var req RPCRequest
	if err := json.Unmarshal(body, &req); err != nil {
		s.writeError(w, nil, ErrCodeParseError, "Invalid JSON")
		return
	}

	if req.JSONRPC != "2.0" {
		s.writeError(w, req.ID, ErrCodeInvalidRequest, "Invalid JSON-RPC version")
		return
	}

	result, rpcErr := s.handleMethod(req.Method, req.Params)
	if rpcErr != nil {
		s.writeResponse(w, &RPCResponse{
			JSONRPC: "2.0",
			Error:   rpcErr,
			ID:      req.ID,
		})
		return
	}

	s.writeResponse(w, &RPCResponse{
		JSONRPC: "2.0",
		Result:  result,
		ID:      req.ID,
	})
}

// handleMethod routes the method to the appropriate handler.
func (s *Server) handleMethod(method string, params json.RawMessage) (interface{}, *RPCError) {
	switch method {
	// Chain methods
	case "x2_chainId":
		return s.chainId()
	case "x2_blockNumber":
		return s.blockNumber()
	case "x2_getBlockByNumber":
		return s.getBlockByNumber(params)

	// Account methods
	case "x2_getBalance":
		return s.getBalance(params)
	case "x2_getAccount":
		return s.getAccount(params)
	case "x2_getNonce":
		return s.getNonce(params)

	// Pool methods
	case "x2_getPool":
		return s.getPool(params)

	// Transaction methods
	case "x2_sendTransaction":
		return s.sendTransaction(params)
	case "x2_pendingTransactionCount":
		return s.pendingTransactionCount()

	// Batch methods
	case "x2_getCurrentBatch":
		return s.getCurrentBatch()
	case "x2_getCompletedBatches":
		return s.getCompletedBatches(params)
	case "x2_getBatchByIndex":
		return s.getBatchByIndex(params)

	default:
		return nil, &RPCError{Code: ErrCodeMethodNotFound, Message: "Method not found"}
	}
}

// Chain methods
func (s *Server) chainId() (interface{}, *RPCError) {
	return "0x2", nil // DEMO chain ID
}

func (s *Server) blockNumber() (interface{}, *RPCError) {
	blk := s.backend.GetLatestBlock()
	if blk == nil {
		return "0x0", nil
	}
	return fmt.Sprintf("0x%x", blk.Number()), nil
}

func (s *Server) getBlockByNumber(params json.RawMessage) (interface{}, *RPCError) {
	var args []interface{}
	if err := json.Unmarshal(params, &args); err != nil || len(args) < 1 {
		return nil, &RPCError{Code: ErrCodeInvalidParams, Message: "Invalid params"}
	}

	blockNum, ok := args[0].(string)
	if !ok {
		return nil, &RPCError{Code: ErrCodeInvalidParams, Message: "Invalid block number"}
	}

	var num uint64
	if blockNum == "latest" {
		blk := s.backend.GetLatestBlock()
		if blk != nil {
			num = blk.Number()
		}
	} else {
		fmt.Sscanf(blockNum, "0x%x", &num)
	}

	blk := s.backend.GetBlockByNumber(num)
	if blk == nil {
		return nil, nil
	}

	txHashes := make([]string, len(blk.Transactions))
	for i, t := range blk.Transactions {
		h := t.Hash()
		txHashes[i] = fmt.Sprintf("0x%x", h[:])
	}

	return &BlockInfo{
		Number:     blk.Number(),
		Hash:       fmt.Sprintf("0x%x", blk.Hash()),
		ParentHash: fmt.Sprintf("0x%x", blk.ParentHash()),
		StateHash:  fmt.Sprintf("0x%x", blk.StateHash()),
		TxRoot:     fmt.Sprintf("0x%x", blk.Header.TransactionsRoot),
		Timestamp:  blk.Header.Timestamp,
		TxCount:    len(blk.Transactions),
		TxHashes:   txHashes,
	}, nil
}

// Account methods
func (s *Server) getBalance(params json.RawMessage) (interface{}, *RPCError) {
	var args []string
	if err := json.Unmarshal(params, &args); err != nil || len(args) < 2 {
		return nil, &RPCError{Code: ErrCodeInvalidParams, Message: "Invalid params: [address, tokenId]"}
	}

	addr := parseAddress(args[0])
	tokenId := parseTokenID(args[1])

	balance := s.backend.GetBalance(addr, tokenId)
	if balance == nil {
		return "0x0", nil
	}
	return fmt.Sprintf("0x%x", balance), nil
}

func (s *Server) getAccount(params json.RawMessage) (interface{}, *RPCError) {
	var args []string
	if err := json.Unmarshal(params, &args); err != nil || len(args) < 1 {
		return nil, &RPCError{Code: ErrCodeInvalidParams, Message: "Invalid params: [address]"}
	}

	addr := parseAddress(args[0])
	return s.backend.GetAccount(addr), nil
}

func (s *Server) getNonce(params json.RawMessage) (interface{}, *RPCError) {
	var args []string
	if err := json.Unmarshal(params, &args); err != nil || len(args) < 1 {
		return nil, &RPCError{Code: ErrCodeInvalidParams, Message: "Invalid params: [address]"}
	}

	addr := parseAddress(args[0])
	acc := s.backend.GetAccount(addr)
	if acc == nil {
		return "0x0", nil
	}
	return fmt.Sprintf("0x%x", acc.Nonce), nil
}

// Pool methods
func (s *Server) getPool(params json.RawMessage) (interface{}, *RPCError) {
	var args []string
	if err := json.Unmarshal(params, &args); err != nil || len(args) < 2 {
		return nil, &RPCError{Code: ErrCodeInvalidParams, Message: "Invalid params: [tokenA, tokenB]"}
	}

	tokenA := parseTokenID(args[0])
	tokenB := parseTokenID(args[1])

	return s.backend.GetPool(tokenA, tokenB), nil
}

// Transaction methods
func (s *Server) sendTransaction(params json.RawMessage) (interface{}, *RPCError) {
	var args []json.RawMessage
	if err := json.Unmarshal(params, &args); err != nil || len(args) < 1 {
		return nil, &RPCError{Code: ErrCodeInvalidParams, Message: "Invalid params"}
	}

	var txData struct {
		Type    uint8  `json:"type"`
		From    string `json:"from"`
		Payload string `json:"payload"` // hex encoded
		Nonce   uint64 `json:"nonce"`
	}

	if err := json.Unmarshal(args[0], &txData); err != nil {
		return nil, &RPCError{Code: ErrCodeInvalidParams, Message: "Invalid transaction data"}
	}

	transaction := &tx.Transaction{
		Type:    types.TxType(txData.Type),
		From:    parseAddress(txData.From),
		Payload: parseHex(txData.Payload),
		Nonce:   txData.Nonce,
	}

	if err := s.backend.SubmitTx(transaction); err != nil {
		return nil, &RPCError{Code: ErrCodeInternalError, Message: err.Error()}
	}

	hash := transaction.Hash()
	return fmt.Sprintf("0x%x", hash[:]), nil
}

func (s *Server) pendingTransactionCount() (interface{}, *RPCError) {
	return s.backend.GetPendingTxCount(), nil
}

// Batch methods
func (s *Server) getCurrentBatch() (interface{}, *RPCError) {
	batch := s.backend.GetCurrentBatch()
	if batch == nil {
		return nil, nil
	}

	return s.batchToResponse(batch), nil
}

func (s *Server) getCompletedBatches(params json.RawMessage) (interface{}, *RPCError) {
	var args []uint64
	if err := json.Unmarshal(params, &args); err != nil {
		args = []uint64{0} // Default: from index 0
	}

	fromIndex := uint64(0)
	if len(args) > 0 {
		fromIndex = args[0]
	}

	batches := s.backend.GetCompletedBatches(fromIndex)
	result := make([]interface{}, len(batches))
	for i, batch := range batches {
		result[i] = s.batchToResponse(batch)
	}
	return result, nil
}

func (s *Server) getBatchByIndex(params json.RawMessage) (interface{}, *RPCError) {
	var args []uint64
	if err := json.Unmarshal(params, &args); err != nil || len(args) < 1 {
		return nil, &RPCError{Code: ErrCodeInvalidParams, Message: "Invalid params: [batchIndex]"}
	}

	batch := s.backend.GetBatchByIndex(args[0])
	if batch == nil {
		return nil, nil
	}
	return s.batchToResponse(batch), nil
}

func (s *Server) batchToResponse(batch *state.Batch) map[string]interface{} {
	return map[string]interface{}{
		"batchIndex":     batch.BatchIndex,
		"startBlock":     batch.StartBlock,
		"endBlock":       batch.EndBlock,
		"blockCount":     len(batch.Blocks),
		"prevStateHash":  fmt.Sprintf("0x%x", batch.PrevStateHash),
		"finalStateHash": fmt.Sprintf("0x%x", batch.FinalStateHash),
		"mptRoot":        fmt.Sprintf("0x%x", batch.MPTRoot),
		"txDataHash":     fmt.Sprintf("0x%x", batch.TxDataHash),
	}
}

// Helper functions
func (s *Server) writeResponse(w http.ResponseWriter, resp *RPCResponse) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func (s *Server) writeError(w http.ResponseWriter, id interface{}, code int, message string) {
	s.writeResponse(w, &RPCResponse{
		JSONRPC: "2.0",
		Error:   &RPCError{Code: code, Message: message},
		ID:      id,
	})
}

func parseAddress(s string) types.Address {
	var addr types.Address
	if len(s) >= 2 && s[:2] == "0x" {
		s = s[2:]
	}
	b := parseHex(s)
	copy(addr[20-len(b):], b)
	return addr
}

func parseTokenID(s string) types.TokenID {
	var id types.TokenID
	if len(s) >= 2 && s[:2] == "0x" {
		s = s[2:]
	}
	b := parseHex(s)
	copy(id[20-len(b):], b)
	return id
}

func parseHex(s string) []byte {
	if len(s) >= 2 && s[:2] == "0x" {
		s = s[2:]
	}
	if len(s)%2 == 1 {
		s = "0" + s
	}
	result := make([]byte, len(s)/2)
	for i := 0; i < len(result); i++ {
		fmt.Sscanf(s[i*2:i*2+2], "%02x", &result[i])
	}
	return result
}
