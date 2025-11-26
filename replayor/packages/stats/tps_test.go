package stats

import (
	"context"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/log"
)

func TestTPSTracker(t *testing.T) {
	logger := log.NewLogger(log.DiscardHandler())
	tracker := NewTPSTracker(logger, "test_tps.log")

	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()

	// Start the tracker
	tracker.Start(ctx)
	defer tracker.Stop()

	// Simulate FCU calls with varying transaction counts
	testCases := []struct {
		txCount int
		delay   time.Duration
	}{
		{100, 100 * time.Millisecond},
		{200, 100 * time.Millisecond},
		{150, 100 * time.Millisecond},
		{300, 100 * time.Millisecond},
		{50, 100 * time.Millisecond},
		{180, 100 * time.Millisecond},
		{220, 100 * time.Millisecond},
		{90, 100 * time.Millisecond},
	}

	totalExpected := uint64(0)
	for _, tc := range testCases {
		tracker.RecordFCU(tc.txCount)
		totalExpected += uint64(tc.txCount)
		time.Sleep(tc.delay)
	}

	// Wait a bit for the tracker to process
	time.Sleep(1 * time.Second)

	// Get stats
	currentTPS, maxTPS, minTPS, totalTxs, lastUpdate := tracker.GetStats()

	// Verify total transactions
	if totalTxs != totalExpected {
		t.Errorf("Expected total txs %d, got %d", totalExpected, totalTxs)
	}

	// Verify stats are reasonable
	if currentTPS <= 0 {
		t.Errorf("Current TPS should be positive, got %.2f", currentTPS)
	}

	if maxTPS < currentTPS {
		t.Errorf("Max TPS %.2f should be >= current TPS %.2f", maxTPS, currentTPS)
	}

	if minTPS > currentTPS {
		t.Errorf("Min TPS %.2f should be <= current TPS %.2f", minTPS, currentTPS)
	}

	if time.Since(lastUpdate) > 2*time.Second {
		t.Errorf("Last update should be recent, was %v ago", time.Since(lastUpdate))
	}

	t.Logf("TPS Stats: Current=%.2f, Max=%.2f, Min=%.2f, Total=%d",
		currentTPS, maxTPS, minTPS, totalTxs)

	// Wait for at least one report cycle (5 seconds) to see the output
	time.Sleep(6 * time.Second)
}

func TestTPSTrackerZeroTransactions(t *testing.T) {
	logger := log.NewLogger(log.DiscardHandler())
	tracker := NewTPSTracker(logger, "")

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	tracker.Start(ctx)
	defer tracker.Stop()

	// Record zero transactions
	tracker.RecordFCU(0)
	time.Sleep(100 * time.Millisecond)
	tracker.RecordFCU(0)

	time.Sleep(1 * time.Second)

	currentTPS, maxTPS, minTPS, totalTxs, _ := tracker.GetStats()

	if totalTxs != 0 {
		t.Errorf("Expected total txs 0, got %d", totalTxs)
	}

	if currentTPS != 0 {
		t.Errorf("Expected current TPS 0, got %.2f", currentTPS)
	}

	if maxTPS != 0 {
		t.Errorf("Expected max TPS 0, got %.2f", maxTPS)
	}

	if minTPS != 0 {
		t.Errorf("Expected min TPS 0, got %.2f", minTPS)
	}
}

func TestTPSTrackerConcurrency(t *testing.T) {
	logger := log.NewLogger(log.DiscardHandler())
	tracker := NewTPSTracker(logger, "")

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	tracker.Start(ctx)
	defer tracker.Stop()

	// Simulate concurrent FCU calls
	done := make(chan bool)
	for i := 0; i < 5; i++ {
		go func() {
			for j := 0; j < 10; j++ {
				tracker.RecordFCU(10)
				time.Sleep(50 * time.Millisecond)
			}
			done <- true
		}()
	}

	// Wait for all goroutines to complete
	for i := 0; i < 5; i++ {
		<-done
	}

	_, _, _, totalTxs, _ := tracker.GetStats()

	expectedTotal := uint64(5 * 10 * 10) // 5 goroutines * 10 iterations * 10 txs
	if totalTxs != expectedTotal {
		t.Errorf("Expected total txs %d, got %d", expectedTotal, totalTxs)
	}
}

