// Package main implements the node entry point (Sequencer + RPC only).
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/ethereum-optimism/optimism/demo/core/block"
	"github.com/ethereum-optimism/optimism/demo/core/state"
	"github.com/ethereum-optimism/optimism/demo/node/rpc"
	"github.com/ethereum-optimism/optimism/demo/node/sequencer"
)

func main() {
	// Parse flags
	blockTime := flag.Duration("block-time", 2*time.Second, "Block production interval")
	batchSize := flag.Int("batch-size", 10, "Blocks per batch")
	rpcAddr := flag.String("rpc-addr", ":8546", "RPC server address")
	flag.Parse()

	log.Println("Starting DEMO Node (Sequencer + RPC)...")

	// Create sequencer config
	seqConfig := &sequencer.Config{
		BlockTime:   *blockTime,
		MaxBlockTxs: 1000,
		BatchSize:   *batchSize,
	}

	// Create sequencer
	seq := sequencer.New(seqConfig)

	// Create RPC server
	backend := rpc.NewSequencerBackend(seq)
	rpcServer := rpc.NewServer(backend)

	// Wire up callbacks
	seq.SetOnNewBlock(func(blk *block.Block) {
		hash := blk.Hash()
		log.Printf("[Sequencer] New block: #%d hash=%x", blk.Number(), hash[:4])
	})

	seq.SetOnNewBatch(func(batch *state.Batch) {
		log.Printf("[Sequencer] New batch ready: index=%d blocks=%d stateHash=%x mptRoot=%x",
			batch.BatchIndex, len(batch.Blocks), batch.FinalStateHash[:8], batch.MPTRoot[:8])
	})

	// Create context for graceful shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Start services
	if err := seq.Start(ctx); err != nil {
		log.Fatalf("Failed to start sequencer: %v", err)
	}
	if err := rpcServer.Start(*rpcAddr); err != nil {
		log.Fatalf("Failed to start RPC server: %v", err)
	}

	log.Println("DEMO Node started successfully")
	log.Printf("Block time: %v, Batch size: %d", *blockTime, *batchSize)
	log.Printf("RPC server listening on %s", *rpcAddr)

	// Wait for shutdown signal
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh

	log.Println("Shutting down...")

	// Stop services
	rpcServer.Stop(ctx)
	seq.Stop()

	log.Println("DEMO Node stopped")
}
