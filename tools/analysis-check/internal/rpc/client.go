package rpc

import (
	"context"
	"fmt"
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/rpc"
)

type Client struct {
	rpc *rpc.Client
	eth *ethclient.Client
}

func NewClient(url string) (*Client, error) {
	rpcClient, err := rpc.Dial(url)
	if err != nil {
		return nil, fmt.Errorf("dial rpc: %w", err)
	}
	ethClient := ethclient.NewClient(rpcClient)
	return &Client{
		rpc: rpcClient,
		eth: ethClient,
	}, nil
}

func (c *Client) Close() {
	c.eth.Close()
}

func (c *Client) ChainID(ctx context.Context) (*big.Int, error) {
	return c.eth.ChainID(ctx)
}

type BlockInfo struct {
	Number       uint64
	Hash         common.Hash
	Transactions types.Transactions
}

func (c *Client) GetBlockNumber(ctx context.Context) (uint64, error) {
	return c.eth.BlockNumber(ctx)
}

func (c *Client) GetBlockByNumber(ctx context.Context, number uint64) (*BlockInfo, error) {
	block, err := c.eth.BlockByNumber(ctx, new(big.Int).SetUint64(number))
	if err != nil {
		return nil, err
	}
	return &BlockInfo{
		Number:       block.NumberU64(),
		Hash:         block.Hash(),
		Transactions: block.Transactions(),
	}, nil
}

func (c *Client) GetBlockByHash(ctx context.Context, hash common.Hash) (*BlockInfo, error) {
	block, err := c.eth.BlockByHash(ctx, hash)
	if err != nil {
		return nil, err
	}
	return &BlockInfo{
		Number:       block.NumberU64(),
		Hash:         block.Hash(),
		Transactions: block.Transactions(),
	}, nil
}

type ReceiptLog struct {
	Address common.Address
	Topics  []common.Hash
	Data    []byte
}

type Receipt struct {
	TxHash common.Hash
	Logs   []*types.Log
}

func (c *Client) GetBlockReceipts(ctx context.Context, blockNum uint64) ([]*types.Receipt, error) {
	var receipts []*types.Receipt
	err := c.rpc.CallContext(ctx, &receipts, "eth_getBlockReceipts", hexutil.EncodeUint64(blockNum))
	if err != nil {
		return nil, err
	}
	return receipts, nil
}

type InnerTx struct {
	From  string `json:"from"`
	To    string `json:"to"`
	Value string `json:"value"`
}

func (c *Client) GetBlockInternalTransactions(ctx context.Context, blockNum uint64) (map[common.Hash][]InnerTx, error) {
	var result map[common.Hash][]InnerTx
	err := c.rpc.CallContext(ctx, &result, "eth_getBlockInternalTransactions", hexutil.EncodeUint64(blockNum))
	if err != nil {
		return nil, err
	}
	return result, nil
}

func (c *Client) GetInternalTransactions(ctx context.Context, txHash common.Hash) ([]InnerTx, error) {
	var result []InnerTx
	err := c.rpc.CallContext(ctx, &result, "eth_getInternalTransactions", txHash)
	if err != nil {
		return nil, err
	}
	return result, nil
}

func (c *Client) BatchGetInternalTransactions(ctx context.Context, txHashes []common.Hash, batchSize int) (map[common.Hash][]InnerTx, error) {
	result := make(map[common.Hash][]InnerTx)

	for i := 0; i < len(txHashes); i += batchSize {
		end := i + batchSize
		if end > len(txHashes) {
			end = len(txHashes)
		}
		batch := txHashes[i:end]

		elems := make([]rpc.BatchElem, len(batch))
		results := make([][]InnerTx, len(batch))
		for j, hash := range batch {
			results[j] = []InnerTx{}
			elems[j] = rpc.BatchElem{
				Method: "eth_getInternalTransactions",
				Args:   []interface{}{hash},
				Result: &results[j],
			}
		}

		if err := c.rpc.BatchCallContext(ctx, elems); err != nil {
			return nil, fmt.Errorf("batch call internal transactions: %w", err)
		}

		for j, hash := range batch {
			if elems[j].Error != nil {
				continue
			}
			result[hash] = results[j]
		}
	}

	return result, nil
}

type BatchBalanceResult struct {
	Address common.Address
	Balance *big.Int
	Error   error
}

func (c *Client) BatchGetBalance(ctx context.Context, addresses []common.Address, blockNum uint64, batchSize int) []BatchBalanceResult {
	blockTag := hexutil.EncodeUint64(blockNum)
	results := make([]BatchBalanceResult, len(addresses))

	for i := 0; i < len(addresses); i += batchSize {
		end := i + batchSize
		if end > len(addresses) {
			end = len(addresses)
		}
		batch := addresses[i:end]

		elems := make([]rpc.BatchElem, len(batch))
		balances := make([]*hexutil.Big, len(batch))
		for j, addr := range batch {
			elems[j] = rpc.BatchElem{
				Method: "eth_getBalance",
				Args:   []interface{}{addr, blockTag},
				Result: &balances[j],
			}
		}

		batchErr := c.rpc.BatchCallContext(ctx, elems)
		for j, addr := range batch {
			idx := i + j
			results[idx].Address = addr
			if batchErr != nil {
				results[idx].Error = batchErr
			} else if elems[j].Error != nil {
				results[idx].Error = elems[j].Error
			} else if balances[j] != nil {
				results[idx].Balance = balances[j].ToInt()
			}
		}
	}

	return results
}

type BatchNonceResult struct {
	Address common.Address
	Nonce   uint64
	Error   error
}

func (c *Client) BatchGetTransactionCount(ctx context.Context, addresses []common.Address, blockNum uint64, batchSize int) []BatchNonceResult {
	blockTag := hexutil.EncodeUint64(blockNum)
	results := make([]BatchNonceResult, len(addresses))

	for i := 0; i < len(addresses); i += batchSize {
		end := i + batchSize
		if end > len(addresses) {
			end = len(addresses)
		}
		batch := addresses[i:end]

		elems := make([]rpc.BatchElem, len(batch))
		nonces := make([]*hexutil.Uint64, len(batch))
		for j, addr := range batch {
			elems[j] = rpc.BatchElem{
				Method: "eth_getTransactionCount",
				Args:   []interface{}{addr, blockTag},
				Result: &nonces[j],
			}
		}

		batchErr := c.rpc.BatchCallContext(ctx, elems)
		for j, addr := range batch {
			idx := i + j
			results[idx].Address = addr
			if batchErr != nil {
				results[idx].Error = batchErr
			} else if elems[j].Error != nil {
				results[idx].Error = elems[j].Error
			} else if nonces[j] != nil {
				results[idx].Nonce = uint64(*nonces[j])
			}
		}
	}

	return results
}

type ERC20BalanceQuery struct {
	Account common.Address
	Token   common.Address
}

type BatchERC20BalanceResult struct {
	Account common.Address
	Token   common.Address
	Balance *big.Int
	Error   error
}

var balanceOfSelector = common.Hex2Bytes("70a08231")

func (c *Client) BatchGetERC20Balances(ctx context.Context, queries []ERC20BalanceQuery, blockNum uint64, batchSize int) []BatchERC20BalanceResult {
	blockTag := hexutil.EncodeUint64(blockNum)
	results := make([]BatchERC20BalanceResult, len(queries))

	for i := 0; i < len(queries); i += batchSize {
		end := i + batchSize
		if end > len(queries) {
			end = len(queries)
		}
		batch := queries[i:end]

		elems := make([]rpc.BatchElem, len(batch))
		balances := make([]*hexutil.Bytes, len(batch))
		for j, q := range batch {
			data := make([]byte, 36)
			copy(data[:4], balanceOfSelector)
			copy(data[4:], common.LeftPadBytes(q.Account.Bytes(), 32))

			callArg := map[string]interface{}{
				"to":   q.Token,
				"data": hexutil.Encode(data),
			}
			elems[j] = rpc.BatchElem{
				Method: "eth_call",
				Args:   []interface{}{callArg, blockTag},
				Result: &balances[j],
			}
		}

		batchErr := c.rpc.BatchCallContext(ctx, elems)
		for j, q := range batch {
			idx := i + j
			results[idx].Account = q.Account
			results[idx].Token = q.Token
			if batchErr != nil {
				results[idx].Error = batchErr
			} else if elems[j].Error != nil {
				results[idx].Error = elems[j].Error
			} else if balances[j] != nil && len(*balances[j]) >= 32 {
				results[idx].Balance = new(big.Int).SetBytes(*balances[j])
			}
		}
	}

	return results
}

func ParseBlockIdentifier(blockArg string) (num uint64, hash common.Hash, isHash bool, err error) {
	blockArg = strings.TrimSpace(blockArg)
	if strings.HasPrefix(blockArg, "0x") && len(blockArg) == 66 {
		hash = common.HexToHash(blockArg)
		isHash = true
		return
	}

	if strings.HasPrefix(blockArg, "0x") {
		n, decErr := hexutil.DecodeUint64(blockArg)
		if decErr != nil {
			err = fmt.Errorf("invalid block identifier: %s", blockArg)
			return
		}
		num = n
		return
	}

	n := new(big.Int)
	if _, ok := n.SetString(blockArg, 10); !ok {
		err = fmt.Errorf("invalid block identifier: %s", blockArg)
		return
	}
	num = n.Uint64()
	return
}
