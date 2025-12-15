package stats

import (
	"context"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/log"
)

// TPSTracker tracks transactions per second statistics for FCU calls
type TPSTracker struct {
	mu  sync.RWMutex
	log log.Logger

	// Current window stats
	currentTPS        float64
	currentTPSWinSize int
	maxTPS            float64
	maxTPSWinSize     int
	minTPS            float64

	// Block stats
	currentBPS float64
	maxBPS     float64
	minBPS     float64

	// Overall stats
	totalTxs    uint64
	totalBlocks uint64
	startTime   time.Time
	lastUpdate  time.Time

	// Circular buffer for TPS calculation
	window     []txEvent
	windowSize time.Duration

	// Control channels
	stopCh chan struct{}
	doneCh chan struct{}

	// Log file path
	logFilePath string
}

type txEvent struct {
	timestamp time.Time
	txCount   int
}

// NewTPSTracker creates a new TPS tracker with a 5-second reporting interval
// logFilePath specifies where to write the latest TPS stats (e.g., "tps.log")
func NewTPSTracker(l log.Logger, logFilePath string) *TPSTracker {
	return &TPSTracker{
		log:         l,
		startTime:   time.Now(),
		lastUpdate:  time.Now(),
		window:      make([]txEvent, 0, 1000),
		windowSize:  5 * time.Second,
		minTPS:      -1, // -1 indicates not initialized
		minBPS:      -1, // -1 indicates not initialized
		stopCh:      make(chan struct{}),
		doneCh:      make(chan struct{}),
		logFilePath: logFilePath,
	}
}

// RecordFCU records a ForkchoiceUpdate call with the number of transactions
func (t *TPSTracker) RecordFCU(txCount int) {
	t.mu.Lock()
	defer t.mu.Unlock()

	now := time.Now()
	event := txEvent{
		timestamp: now,
		txCount:   txCount,
	}

	t.window = append(t.window, event)
	t.totalTxs += uint64(txCount)
	t.totalBlocks++ // Each FCU call represents a block
	t.lastUpdate = now

	// Clean up old events outside the window
	cutoff := now.Add(-t.windowSize)
	validIdx := 0
	for i, e := range t.window {
		if e.timestamp.After(cutoff) {
			validIdx = i
			break
		}
	}
	if validIdx > 0 {
		t.window = t.window[validIdx:]
	}

	// Calculate current TPS and BPS
	t.calculateTPS()
	t.calculateBPS()
}

// calculateTPS calculates TPS for the current window (must be called with lock held)
func (t *TPSTracker) calculateTPS() {
	if len(t.window) == 0 {
		t.currentTPS = 0
		return
	}

	now := time.Now()
	cutoff := now.Add(-t.windowSize)

	txCount := 0
	oldestTime := now

	winCount := 0
	for _, e := range t.window {
		if e.timestamp.After(cutoff) {
			txCount += e.txCount
			if e.timestamp.Before(oldestTime) {
				oldestTime = e.timestamp
			}
			winCount++
		}
	}

	duration := now.Sub(oldestTime).Seconds()
	if duration > 0 {
		t.currentTPS = float64(txCount) / duration
		t.currentTPSWinSize = winCount
		// Update max TPS
		if t.currentTPS > t.maxTPS && winCount >= 3 {
			t.maxTPS = t.currentTPS
			t.maxTPSWinSize = t.maxTPSWinSize
		}

		// Update min TPS (only if we have meaningful data)
		if t.minTPS < 0 || (t.currentTPS > 0 && t.currentTPS < t.minTPS) {
			t.minTPS = t.currentTPS
		}
	}
}

// calculateBPS calculates blocks per second for the current window (must be called with lock held)
func (t *TPSTracker) calculateBPS() {
	if len(t.window) == 0 {
		t.currentBPS = 0
		return
	}

	now := time.Now()
	cutoff := now.Add(-t.windowSize)

	blockCount := 0
	oldestTime := now

	for _, e := range t.window {
		if e.timestamp.After(cutoff) {
			blockCount++ // Each event represents a block
			if e.timestamp.Before(oldestTime) {
				oldestTime = e.timestamp
			}
		}
	}

	duration := now.Sub(oldestTime).Seconds()
	if duration > 0 {
		t.currentBPS = float64(blockCount) / duration
		// Update max BPS
		if t.currentBPS > t.maxBPS && blockCount >= 3 {
			t.maxBPS = t.currentBPS
		}

		// Update min BPS (only if we have meaningful data)
		if t.minBPS < 0 || (t.currentBPS > 0 && t.currentBPS < t.minBPS) {
			t.minBPS = t.currentBPS
		}
	}
}

// Start begins the periodic reporting goroutine
func (t *TPSTracker) Start(ctx context.Context) {
	go t.reportLoop(ctx)
}

// reportLoop periodically prints TPS statistics every 5 seconds
func (t *TPSTracker) reportLoop(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	defer close(t.doneCh)

	for {
		select {
		case <-ctx.Done():
			t.printStats(true)
			return
		case <-t.stopCh:
			t.printStats(true)
			return
		case <-ticker.C:
			t.printStats(false)
		}
	}
}

// printStats outputs the current statistics to stdout and log file
func (t *TPSTracker) printStats(final bool) {
	t.mu.RLock()
	defer t.mu.RUnlock()

	prefix := "TPS Stats"
	if final {
		prefix = "Final TPS Stats"
	}

	minTPS := t.minTPS
	if minTPS < 0 {
		minTPS = 0
	}

	minBPS := t.minBPS
	if minBPS < 0 {
		minBPS = 0
	}

	uptime := time.Since(t.startTime)
	avgTPS := 0.0
	if uptime.Seconds() > 0 {
		avgTPS = float64(t.totalTxs) / uptime.Seconds()
	}

	avgBPS := 0.0
	if uptime.Seconds() > 0 {
		avgBPS = float64(t.totalBlocks) / uptime.Seconds()
	}

	// Print to both logger and stdout
	output := fmt.Sprintf("\n========== %s ==========\n", prefix)
	output += fmt.Sprintf("Current TPS:  %.2f tx/s\n", t.currentTPS)
	output += fmt.Sprintf("Average TPS:  %.2f tx/s\n", avgTPS)
	output += fmt.Sprintf("Max TPS:      %.2f tx/s\n", t.maxTPS)
	output += fmt.Sprintf("Min TPS:      %.2f tx/s\n", minTPS)
	output += fmt.Sprintf("Total Txs:    %d\n", t.totalTxs)
	output += fmt.Sprintf("Current BPS:  %.2f block/s\n", t.currentBPS)
	output += fmt.Sprintf("Average BPS:  %.2f block/s\n", avgBPS)
	output += fmt.Sprintf("Max BPS:      %.2f block/s\n", t.maxBPS)
	output += fmt.Sprintf("Min BPS:      %.2f block/s\n", minBPS)
	output += fmt.Sprintf("Total Blocks: %d\n", t.totalBlocks)
	output += fmt.Sprintf("Last Update:  %s\n", t.lastUpdate.Format("2006-01-02 15:04:05"))
	output += fmt.Sprintf("Uptime:       %s\n", uptime.Round(time.Second))
	output += "=====================================\n\n"

	// Print to stdout
	fmt.Print(output)

	// Write to log file (overwrite with latest stats)
	if t.logFilePath != "" {
		err := os.WriteFile(t.logFilePath, []byte(output), 0644)
		if err != nil {
			t.log.Warn("Failed to write TPS log file", "path", t.logFilePath, "err", err)
		}
	}

	t.log.Info("TPS statistics",
		"currentTPS", fmt.Sprintf("%.2f", t.currentTPS),
		"avgTPS", fmt.Sprintf("%.2f", avgTPS),
		"maxTPS", fmt.Sprintf("%.2f", t.maxTPS),
		"minTPS", fmt.Sprintf("%.2f", minTPS),
		"totalTxs", t.totalTxs,
		"currentBPS", fmt.Sprintf("%.2f", t.currentBPS),
		"avgBPS", fmt.Sprintf("%.2f", avgBPS),
		"maxBPS", fmt.Sprintf("%.2f", t.maxBPS),
		"minBPS", fmt.Sprintf("%.2f", minBPS),
		"totalBlocks", t.totalBlocks,
		"uptime", uptime.Round(time.Second).String(),
	)
}

// Stop stops the reporting goroutine
func (t *TPSTracker) Stop() {
	close(t.stopCh)
	<-t.doneCh
}

// GetStats returns the current statistics (thread-safe)
func (t *TPSTracker) GetStats() (currentTPS, maxTPS, minTPS, currentBPS, maxBPS, minBPS float64, totalTxs, totalBlocks uint64, lastUpdate time.Time) {
	t.mu.RLock()
	defer t.mu.RUnlock()

	minTPS = t.minTPS
	if minTPS < 0 {
		minTPS = 0
	}

	minBPS = t.minBPS
	if minBPS < 0 {
		minBPS = 0
	}

	return t.currentTPS, t.maxTPS, minTPS, t.currentBPS, t.maxBPS, minBPS, t.totalTxs, t.totalBlocks, t.lastUpdate
}
