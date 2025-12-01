package replayor

import (
	"context"
	"fmt"
	"math/big"
	"sync"
	"time"

	"github.com/danyalprout/replayor/packages/clients"
	"github.com/danyalprout/replayor/packages/stats"
	"github.com/danyalprout/replayor/packages/strategies"
	"github.com/ethereum-optimism/optimism/op-node/rollup"
	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum-optimism/optimism/op-service/retry"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/consensus/misc/eip1559"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/log"
	"github.com/ethereum/go-ethereum/rpc"
)

const (
	concurrency        = 8000
	fetchGoroutinePool = 8000
)

type Benchmark struct {
	clients clients.Clients
	s       stats.Stats

	log log.Logger

	currentBlock *types.Block

	incomingBlocks chan *types.Block
	processBlocks  chan strategies.BlockCreationParams

	previousReplayedBlockHash common.Hash
	strategy                  strategies.Strategy

	remainingBlockCount uint64
	rollupCfg           *rollup.Config
	startBlockNum       uint64
	endBlockNum         uint64
	continuous          bool

	benchmarkOpcodes bool
	diffStorage      bool

	tpsTracker *stats.TPSTracker
}

func (r *Benchmark) getBlockFromSourceNode(ctx context.Context, blockNum uint64) (*types.Block, error) {
	return retry.Do(ctx, 10, retry.Exponential(), func() (*types.Block, error) {
		return r.clients.SourceNode.BlockByNumber(ctx, big.NewInt(int64(blockNum)))
	})
}

func (r *Benchmark) getLatestBlockFromDestNode(ctx context.Context) (*types.Block, error) {
	return retry.Do(ctx, 10, retry.Exponential(), func() (*types.Block, error) {
		return r.clients.DestNode.BlockByNumber(ctx, nil)
	})
}

func (r *Benchmark) getLatestBlockFromSourceNode(ctx context.Context) (*types.Block, error) {
	return retry.Do(ctx, 10, retry.Exponential(), func() (*types.Block, error) {
		return r.clients.SourceNode.BlockByNumber(ctx, nil)
	})
}

func (r *Benchmark) loadBlocks(ctx context.Context) {
	if r.continuous {
		r.loadBlocksContinuous(ctx)
	} else {
		r.loadBlocksFixed(ctx)
	}
}

func (r *Benchmark) loadBlocksFixed(ctx context.Context) {
	for blockStartRange := r.startBlockNum; blockStartRange <= r.endBlockNum; blockStartRange += concurrency {
		results := make([]*types.Block, concurrency)

		var wg sync.WaitGroup

		var m sync.Mutex

		for i := uint64(0); i < concurrency; i++ {
			blockNum := blockStartRange + i
			if blockNum > r.endBlockNum {
				break
			}

			wg.Add(1)

			go func(index, blockNum uint64) {
				defer wg.Done()

				block, err := r.getBlockFromSourceNode(ctx, blockNum)
				if err != nil {
					r.log.Error("failed to getBlockFromSourceNode", "blockNum", blockNum, "err", err)
					panic(err)
				}
				fmt.Println("Loading block:", blockNum)

				if block == nil {
					panic(fmt.Errorf("unexpected nil block: %d", blockNum))
				}

				m.Lock()
				results[index] = block
				m.Unlock()
			}(i, blockNum)
		}

		wg.Wait()

		for _, block := range results {
			if block != nil {
				r.incomingBlocks <- block
			}
		}
	}

	r.log.Info("finished loading blocks, closing channel")
	close(r.incomingBlocks)
}

func (r *Benchmark) loadBlocksContinuous(ctx context.Context) {
	currentBlockNum := r.startBlockNum
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			r.log.Info("stopping continuous block loading")
			close(r.incomingBlocks)
			return
		case <-ticker.C:
			// Get latest block from source node
			latestBlock, err := r.getLatestBlockFromSourceNode(ctx)
			if err != nil {
				r.log.Error("failed to get latest block from source node", "err", err)
				continue
			}

			latestBlockNum := latestBlock.NumberU64()

			// Load blocks from current to latest using goroutine pool
			if currentBlockNum <= latestBlockNum {
				// Create channels for distributing work and collecting results
				blockNumChan := make(chan uint64, fetchGoroutinePool)
				blockResultChan := make(chan *types.Block, fetchGoroutinePool*2)

				var fetchWg sync.WaitGroup

				// Start fetcher goroutines (N=256)
				for i := 0; i < fetchGoroutinePool; i++ {
					fetchWg.Add(1)
					go func() {
						defer fetchWg.Done()
						for blockNum := range blockNumChan {
							for {
								block, err := r.getBlockFromSourceNode(ctx, blockNum)
								if err != nil {
									r.log.Error("failed to getBlockFromSourceNode", "blockNum", blockNum, "err", err)
									time.Sleep(2 * time.Second)
									continue
								}
								if block == nil {
									r.log.Warn("received nil block", "blockNum", blockNum)
									time.Sleep(2 * time.Second)
									continue
								}
								blockResultChan <- block
								break
							}
						}
					}()
				}

				// Goroutine to dispatch block numbers
				go func() {
					for blockNum := currentBlockNum; blockNum <= latestBlockNum; blockNum++ {
						select {
						case blockNumChan <- blockNum:
						case <-ctx.Done():
							close(blockNumChan)
							return
						}
					}
					close(blockNumChan)
				}()

				// Goroutine to close result channel after all fetchers are done
				go func() {
					fetchWg.Wait()
					close(blockResultChan)
				}()

				// Collect blocks into map and write them in order
				blockMap := make(map[uint64]*types.Block)
				var mu sync.Mutex
				collectorDone := make(chan struct{})

				// Collect all results into map
				go func() {
					for block := range blockResultChan {
						mu.Lock()
						blockMap[block.NumberU64()] = block
						mu.Unlock()
					}
					close(collectorDone)
				}()

				// Write blocks in strict order by block number
				for currentBlockNum <= latestBlockNum {
					// Wait for the specific block we need
					var block *types.Block
					for {
						mu.Lock()
						b, exists := blockMap[currentBlockNum]
						if exists {
							block = b
							delete(blockMap, currentBlockNum)
						}
						mu.Unlock()

						if exists {
							break
						}

						// Check if collector is done and block still doesn't exist
						select {
						case <-collectorDone:
							r.log.Error("block not found after all fetching completed", "blockNum", currentBlockNum)
							// This shouldn't happen, but if it does, try to fetch it directly
							var err error
							block, err = r.getBlockFromSourceNode(ctx, currentBlockNum)
							if err != nil || block == nil {
								r.log.Error("failed to fetch missing block", "blockNum", currentBlockNum, "err", err)
								time.Sleep(2 * time.Second)
								continue
							}
							goto writeBlock
						case <-ctx.Done():
							r.log.Info("stopping continuous block loading")
							close(r.incomingBlocks)
							return
						default:
							// Block not ready yet, wait a bit
							time.Sleep(10 * time.Millisecond)
						}
					}

				writeBlock:
					// Write block to channel in order
					select {
					case r.incomingBlocks <- block:
						currentBlockNum++
					case <-ctx.Done():
						r.log.Info("stopping continuous block loading")
						close(r.incomingBlocks)
						return
					}
				}
			}

			// If we've caught up, wait a bit before checking again
			if currentBlockNum > latestBlockNum {
				time.Sleep(2 * time.Second)
			}
		}
	}
}

func (r *Benchmark) addBlock(ctx context.Context, currentBlock strategies.BlockCreationParams) {
	l := r.log.New("source", "add-block", "block", currentBlock.Number)
	l.Info("processing new block")

	stats := stats.BlockCreationStats{}

	txns := currentBlock.Transactions

	stats.TxnCount = len(txns)

	state := &eth.ForkchoiceState{
		HeadBlockHash:      r.previousReplayedBlockHash,
		SafeBlockHash:      r.previousReplayedBlockHash,
		FinalizedBlockHash: r.previousReplayedBlockHash,
	}

	txnData := make([]eth.Data, len(txns))
	for i, txn := range txns {
		data, err := txn.MarshalBinary()
		if err != nil {
			panic(err)
		}
		txnData[i] = data
		stats.GasLimit += txn.Gas()
	}

	attrs := &eth.PayloadAttributes{
		Timestamp:             currentBlock.Time,
		NoTxPool:              true,
		SuggestedFeeRecipient: currentBlock.FeeRecipient,
		Transactions:          txnData,
		GasLimit:              currentBlock.GasLimit,
		PrevRandao:            currentBlock.MixDigest,
		ParentBeaconBlockRoot: currentBlock.BeaconRoot,
		Withdrawals:           &currentBlock.Withdrawals,
	}

	if r.rollupCfg.IsHolocene(uint64(currentBlock.Time)) {
		l.Info("holocene block", "holoceneTime", r.rollupCfg.HoloceneTime)
		d, e := eip1559.DecodeHoloceneExtraData(currentBlock.Extra)
		eip1559Params := eip1559.EncodeHolocene1559Params(d, e)
		var params eth.Bytes8
		copy(params[:], eip1559Params)
		attrs.EIP1559Params = &params
	}

	var totalTime time.Duration

	startTime := time.Now()
	result, err := r.clients.EngineApi.ForkchoiceUpdate(ctx, state, attrs)
	fcuEnd := time.Now()

	if err != nil {
		l.Crit("forkchoice update with attrs failed", "err", err)
	}

	if result.PayloadStatus.Status != eth.ExecutionValid {
		l.Crit("forkchoice update with attrs failed", "status", result.PayloadStatus.Status)
	}

	stats.FCUTime = fcuEnd.Sub(startTime)
	totalTime += stats.FCUTime

	// Record TPS for FCU with transactions
	r.tpsTracker.RecordFCU(len(txns))

	envelope, err := r.clients.EngineApi.GetPayload(ctx, eth.PayloadInfo{
		ID:        *result.PayloadID,
		Timestamp: uint64(currentBlock.Time),
	})
	if err != nil {
		l.Crit("get payload failed", "err", err, "payloadId", *result.PayloadID)
	}

	getTime := time.Now()
	stats.GetTime = getTime.Sub(fcuEnd)
	totalTime += stats.GetTime

	err = r.strategy.ValidateExecution(ctx, envelope, currentBlock)
	if err != nil {
		txnHash := make([]common.Hash, len(txns))
		for i, txn := range txns {
			txnHash[i] = txn.Hash()
		}

		l.Crit("validation failed", "err", err, "executionPayload", *envelope.ExecutionPayload, "parentBeaconBlockRoot", envelope.ParentBeaconBlockRoot, "txnHashes", txnHash)
	}

	newStart := time.Now()
	status, err := r.clients.EngineApi.NewPayload(ctx, envelope.ExecutionPayload, envelope.ParentBeaconBlockRoot)
	if err != nil {
		l.Crit("new payload failed", "err", err)
	}

	newEnd := time.Now()
	stats.NewTime = newEnd.Sub(newStart)
	totalTime += stats.NewTime

	if status.Status != eth.ExecutionValid {
		l.Crit("new payload failed", "status", status.Status)
	}

	state = &eth.ForkchoiceState{
		HeadBlockHash:      envelope.ExecutionPayload.BlockHash,
		SafeBlockHash:      envelope.ExecutionPayload.BlockHash,
		FinalizedBlockHash: envelope.ExecutionPayload.BlockHash,
	}

	fcu2status, err := r.clients.EngineApi.ForkchoiceUpdate(ctx, state, nil)
	if err != nil {
		l.Crit("forkchoice update nil attrs failed", "err", err)
	}
	fcu2Time := time.Now()
	stats.FCUNoAttrsTime = fcu2Time.Sub(newEnd)
	totalTime += stats.FCUNoAttrsTime

	if fcu2status.PayloadStatus.Status != eth.ExecutionValid {
		l.Crit("forkchoice update nil attrs failed", "status", fcu2status.PayloadStatus.Status)
	}

	err = r.strategy.ValidateBlock(ctx, envelope, currentBlock)
	if err != nil {
		l.Crit("validation failed", "err", err)
	}

	stats.TotalTime = totalTime
	stats.BlockNumber = uint64(envelope.ExecutionPayload.BlockNumber)
	stats.BlockHash = envelope.ExecutionPayload.BlockHash

	r.previousReplayedBlockHash = envelope.ExecutionPayload.BlockHash

	r.enrich(ctx, &stats)
	l.Info("block stats", "previousReplayedBlockHash", r.previousReplayedBlockHash.String(), "totalTime", stats.TotalTime, "gasUsed", stats.GasUsed, "txCount", stats.TxnCount)

	r.s.RecordBlockStats(stats)
}

func (r *Benchmark) enrich(ctx context.Context, s *stats.BlockCreationStats) {
	receipts, err := retry.Do(ctx, 3, retry.Exponential(), func() ([]*types.Receipt, error) {
		return r.clients.DestNode.BlockReceipts(ctx, rpc.BlockNumberOrHash{BlockHash: &s.BlockHash})
	})
	if err != nil {
		r.log.Warn("unable to load receipts", "err", err)
		return
	}

	success := 0
	for _, receipt := range receipts {
		s.GasUsed += receipt.GasUsed
		if receipt.Status == types.ReceiptStatusSuccessful {
			success += 1
		}
	}
	s.Success = float64(success) / float64(len(receipts))

	r.computeTraceStats(ctx, s, receipts)
}

func (r *Benchmark) submitBlocks(ctx context.Context) {
	for {
		select {
		case block, ok := <-r.processBlocks:
			if !ok {
				r.log.Info("stopping block processing")
				return
			}

			// In continuous mode, we don't check endBlockNum
			if !r.continuous && block.Number > r.endBlockNum {
				r.log.Info("stopping block processing", "block", block.Number, "endBlock", r.endBlockNum)
				return
			}

			r.addBlock(ctx, block)
			if !r.continuous {
				r.remainingBlockCount -= 1
			}
		case <-ctx.Done():
			return
		}
	}
}

func (r *Benchmark) mapBlocks(ctx context.Context) {
	defer r.log.Info("stopping block mapping")
	for {
		select {
		case b, ok := <-r.incomingBlocks:
			if !ok {
				close(r.processBlocks)
				return
			} else if b == nil {
				r.log.Warn("nil block received")
				continue
			}

			params := r.strategy.BlockReceived(ctx, b)
			if params == nil {
				continue
			}

			r.processBlocks <- *params
		case <-ctx.Done():
			return
		}
	}
}

func (r *Benchmark) Run(ctx context.Context) {
	r.log.Info("benchmark run initiated")

	// Start TPS tracker
	r.tpsTracker.Start(ctx)
	defer r.tpsTracker.Stop()

	doneChan := make(chan any)
	go r.loadBlocks(ctx)
	go r.mapBlocks(ctx)
	go func() {
		r.submitBlocks(ctx)
		close(doneChan)
	}()

	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	l := r.log.New("source", "monitor")

	lastBlockNum := r.currentBlock.NumberU64()

	for {
		select {
		case <-doneChan:
			r.s.Write(ctx)
			return
		case <-ticker.C:
			currentBlock, err := r.getLatestBlockFromDestNode(ctx)
			if err != nil {
				r.log.Error("unable to load current block from dest node", "err", err)
				panic(err)
			}

			remainingInfo := "N/A"
			if !r.continuous {
				remainingInfo = fmt.Sprintf("%d", r.remainingBlockCount)
			}
			l.Info("replay progress", "blocks", currentBlock.NumberU64()-lastBlockNum, "incomingBlocks", len(r.incomingBlocks), "processBlocks", len(r.processBlocks), "currentBlock", currentBlock.NumberU64(), "remaining", remainingInfo, "continuous", r.continuous)
			lastBlockNum = currentBlock.NumberU64()

			// Periodically write to disk to save progress in case test is interrupted
			lastBlockWritten := r.s.GetLastBlockWritten()
			if lastBlockNum-lastBlockWritten >= 100 {
				r.s.Write(ctx)
			}
		case <-ctx.Done():
			return
		}
	}
}

// Start block
// End block
func NewBenchmark(
	c clients.Clients,
	rollupCfg *rollup.Config,
	logger log.Logger,
	strategy strategies.Strategy,
	s stats.Stats,
	currentBlock *types.Block,
	benchmarkBlockCount uint64,
	continuous bool,
	benchmarkOpcodes bool,
	diffStorage bool,
) *Benchmark {
	var endBlockNum uint64
	if continuous {
		// In continuous mode, set a very large endBlockNum as a placeholder
		// The actual end will be determined by the source node's latest block
		endBlockNum = ^uint64(0) // Max uint64
	} else {
		endBlockNum = currentBlock.NumberU64() + benchmarkBlockCount
	}

	r := &Benchmark{
		clients:                   c,
		rollupCfg:                 rollupCfg,
		log:                       logger,
		incomingBlocks:            make(chan *types.Block, 20000),
		processBlocks:             make(chan strategies.BlockCreationParams, 20000),
		strategy:                  strategy,
		s:                         s,
		currentBlock:              currentBlock,
		startBlockNum:             currentBlock.NumberU64() + 1,
		endBlockNum:               endBlockNum,
		remainingBlockCount:       benchmarkBlockCount,
		continuous:                continuous,
		previousReplayedBlockHash: currentBlock.Hash(),
		benchmarkOpcodes:          benchmarkOpcodes,
		diffStorage:               diffStorage,
		tpsTracker:                stats.NewTPSTracker(logger, "tps.log"),
	}

	return r
}

