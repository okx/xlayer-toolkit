package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/okx/xlayer-toolkit/tools/analysis-check/internal/analyzer"
	"github.com/okx/xlayer-toolkit/tools/analysis-check/internal/rpc"
	"github.com/urfave/cli/v2"
)

var (
	rpcURLFlag = &cli.StringFlag{
		Name:     "rpc-url",
		Usage:    "RPC endpoint URL",
		Required: true,
	}
	blockFlag = &cli.StringFlag{
		Name:  "block",
		Usage: "Block number or hash to analyze (if not set, follows latest blocks)",
	}
	innerTxFlag = &cli.StringFlag{
		Name:  "innertx",
		Usage: "Internal transaction fetch mode: 'block' or 'tx'",
		Value: "block",
	}
	batchSizeFlag = &cli.IntFlag{
		Name:  "batch-size",
		Usage: "Batch size for RPC requests",
		Value: 200,
	}
	pollIntervalFlag = &cli.DurationFlag{
		Name:  "poll-interval",
		Usage: "Polling interval for latest block mode",
		Value: time.Second,
	}
)

func main() {
	app := &cli.App{
		Name:  "analysis-check",
		Usage: "Simulate block analysis by fetching block data, receipts, internal transactions, and account states",
		Flags: []cli.Flag{
			rpcURLFlag,
			blockFlag,
			innerTxFlag,
			batchSizeFlag,
			pollIntervalFlag,
		},
		Action: run,
	}

	if err := app.Run(os.Args); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func run(c *cli.Context) error {
	rpcURL := c.String("rpc-url")
	blockArg := c.String("block")
	innerTxMode := c.String("innertx")
	batchSize := c.Int("batch-size")
	pollInterval := c.Duration("poll-interval")

	if innerTxMode != "block" && innerTxMode != "tx" {
		return fmt.Errorf("invalid innertx mode: %s (must be 'block' or 'tx')", innerTxMode)
	}

	client, err := rpc.NewClient(rpcURL)
	if err != nil {
		return fmt.Errorf("create rpc client: %w", err)
	}
	defer client.Close()

	a := analyzer.New(client, analyzer.Config{
		InnerTxMode: innerTxMode,
		BatchSize:   batchSize,
	})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		fmt.Println("\nShutting down...")
		cancel()
	}()

	if blockArg != "" {
		return runSingleBlock(ctx, a, blockArg)
	}
	return runLoop(ctx, client, a, pollInterval)
}

func runSingleBlock(ctx context.Context, a *analyzer.Analyzer, blockArg string) error {
	num, hash, isHash, err := rpc.ParseBlockIdentifier(blockArg)
	if err != nil {
		return err
	}

	var result *analyzer.Result
	if isHash {
		result, err = a.AnalyzeBlockByHash(ctx, hash)
	} else {
		result, err = a.AnalyzeBlockByNumber(ctx, num)
	}
	if err != nil {
		return fmt.Errorf("analyze block: %w", err)
	}

	printResult(result)
	return nil
}

func runLoop(ctx context.Context, client *rpc.Client, a *analyzer.Analyzer, pollInterval time.Duration) error {
	var lastProcessed uint64

	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			latestNum, err := client.GetBlockNumber(ctx)
			if err != nil {
				fmt.Fprintf(os.Stderr, "get block number: %v\n", err)
				continue
			}

			if latestNum <= lastProcessed {
				continue
			}

			for blockNum := lastProcessed + 1; blockNum <= latestNum; blockNum++ {
				if lastProcessed == 0 {
					blockNum = latestNum
				}

				select {
				case <-ctx.Done():
					return nil
				default:
				}

				result, err := a.AnalyzeBlockByNumber(ctx, blockNum)
				if err != nil {
					fmt.Fprintf(os.Stderr, "analyze block %d: %v\n", blockNum, err)
					continue
				}

				printResult(result)
				lastProcessed = blockNum
			}
		}
	}
}

func printResult(r *analyzer.Result) {
	fmt.Printf("block=%d, hash=%s, txs=%d, accounts=%d, tokens=%d, innerTxs=%d, analysis elapse: %d ms\n",
		r.BlockNumber, r.BlockHash.Hex(), r.TxCount, r.AccountCount, r.TokenCount, r.InnerTxCount, r.ElapsedMs)
}
