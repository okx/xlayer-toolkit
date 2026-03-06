package analyzer

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/okx/xlayer-toolkit/tools/analysis-check/internal/rpc"
)

var transferEventSig = common.HexToHash("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")

type Config struct {
	InnerTxMode string
	BatchSize   int
}

type Result struct {
	BlockNumber  uint64
	BlockHash    common.Hash
	TxCount      int
	AccountCount int
	TokenCount   int
	InnerTxCount int
	ElapsedMs    int64
}

type Analyzer struct {
	client *rpc.Client
	cfg    Config
}

func New(client *rpc.Client, cfg Config) *Analyzer {
	return &Analyzer{
		client: client,
		cfg:    cfg,
	}
}

func (a *Analyzer) AnalyzeBlockByNumber(ctx context.Context, blockNum uint64) (*Result, error) {
	start := time.Now()

	block, err := a.client.GetBlockByNumber(ctx, blockNum)
	if err != nil {
		return nil, fmt.Errorf("get block by number: %w", err)
	}

	return a.analyzeBlock(ctx, block, start)
}

func (a *Analyzer) AnalyzeBlockByHash(ctx context.Context, hash common.Hash) (*Result, error) {
	start := time.Now()

	block, err := a.client.GetBlockByHash(ctx, hash)
	if err != nil {
		return nil, fmt.Errorf("get block by hash: %w", err)
	}

	return a.analyzeBlock(ctx, block, start)
}

func (a *Analyzer) analyzeBlock(ctx context.Context, block *rpc.BlockInfo, start time.Time) (*Result, error) {
	receipts, err := a.client.GetBlockReceipts(ctx, block.Number)
	if err != nil {
		return nil, fmt.Errorf("get block receipts: %w", err)
	}

	tokenContracts := make(map[common.Address]struct{})
	for _, receipt := range receipts {
		for _, log := range receipt.Logs {
			if len(log.Topics) > 0 && log.Topics[0] == transferEventSig {
				tokenContracts[log.Address] = struct{}{}
			}
		}
	}

	accounts := make(map[common.Address]struct{})
	for _, tx := range block.Transactions {
		if tx.To() != nil {
			accounts[*tx.To()] = struct{}{}
		}
		from, err := types.Sender(types.LatestSignerForChainID(tx.ChainId()), tx)
		if err == nil {
			accounts[from] = struct{}{}
		}
	}

	var innerTxMap map[common.Hash][]rpc.InnerTx
	if a.cfg.InnerTxMode == "block" {
		innerTxMap, err = a.client.GetBlockInternalTransactions(ctx, block.Number)
		if err != nil {
			return nil, fmt.Errorf("get block internal transactions: %w", err)
		}
	} else {
		txHashes := make([]common.Hash, len(block.Transactions))
		for i, tx := range block.Transactions {
			txHashes[i] = tx.Hash()
		}
		innerTxMap, err = a.client.BatchGetInternalTransactions(ctx, txHashes, a.cfg.BatchSize)
		if err != nil {
			return nil, fmt.Errorf("batch get internal transactions: %w", err)
		}
	}

	innerTxCount := 0
	for _, txInners := range innerTxMap {
		for _, inner := range txInners {
			innerTxCount++
			if inner.From != "" {
				fromAddr := parseAddress(inner.From)
				if fromAddr != (common.Address{}) {
					accounts[fromAddr] = struct{}{}
				}
			}
			if inner.To != "" {
				toAddr := parseAddress(inner.To)
				if toAddr != (common.Address{}) {
					accounts[toAddr] = struct{}{}
				}
			}
		}
	}

	accountList := make([]common.Address, 0, len(accounts))
	for addr := range accounts {
		accountList = append(accountList, addr)
	}

	tokenList := make([]common.Address, 0, len(tokenContracts))
	for token := range tokenContracts {
		tokenList = append(tokenList, token)
	}

	_ = a.client.BatchGetBalance(ctx, accountList, block.Number, a.cfg.BatchSize)
	_ = a.client.BatchGetTransactionCount(ctx, accountList, block.Number, a.cfg.BatchSize)

	if len(tokenList) > 0 && len(accountList) > 0 {
		queries := make([]rpc.ERC20BalanceQuery, 0, len(accountList)*len(tokenList))
		for _, acc := range accountList {
			for _, tok := range tokenList {
				queries = append(queries, rpc.ERC20BalanceQuery{
					Account: acc,
					Token:   tok,
				})
			}
		}
		_ = a.client.BatchGetERC20Balances(ctx, queries, block.Number, a.cfg.BatchSize)
	}

	elapsed := time.Since(start)

	return &Result{
		BlockNumber:  block.Number,
		BlockHash:    block.Hash,
		TxCount:      len(block.Transactions),
		AccountCount: len(accountList),
		TokenCount:   len(tokenList),
		InnerTxCount: innerTxCount,
		ElapsedMs:    elapsed.Milliseconds(),
	}, nil
}

func parseAddress(s string) common.Address {
	s = strings.TrimSpace(s)
	if s == "" {
		return common.Address{}
	}
	return common.HexToAddress(s)
}
