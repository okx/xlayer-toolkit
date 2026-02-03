// Package proposer implements the DEMO proposer service.
// Proposer calculates MPT root, submits state commitments to L1,
// and defends against invalid challenges.
package proposer

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/ethereum-optimism/optimism/demo/core/state"
	"github.com/ethereum-optimism/optimism/demo/core/types"
)

// L1Client interface for L1 interactions.
type L1Client interface {
	SubmitOutput(ctx context.Context, output *state.Output) error
	GetLatestOutputIndex() (uint64, error)

	// Defense methods
	HasActiveDispute(ctx context.Context, batchIndex uint64) (bool, error)
	GetOutputMPTRoot(ctx context.Context, batchIndex uint64) (types.Hash, error)
	Defend(ctx context.Context, gameAddr common.Address, parentIndex uint64, claim types.Hash) error
	CanResolve(ctx context.Context, gameAddr common.Address) (bool, error)
	Resolve(ctx context.Context, gameAddr common.Address) error
	GetClaimCount(ctx context.Context, gameAddr common.Address) (uint64, error)
}

// Config holds proposer configuration.
type Config struct {
	SubmitInterval    time.Duration
	OutputSubmitDelay time.Duration // Delay after batch submission
	ChallengeWindow   time.Duration // Time window for challenges
	DefenseEnabled    bool          // Whether to actively defend challenges
	DefenseInterval   time.Duration // How often to check for challenges
}

// DefaultConfig returns default proposer config.
func DefaultConfig() *Config {
	return &Config{
		SubmitInterval:    10 * time.Second, // Fast for demo
		OutputSubmitDelay: 1 * time.Second,
		ChallengeWindow:   5 * time.Minute, // 5 minutes for demo
		DefenseEnabled:    true,
		DefenseInterval:   5 * time.Second,
	}
}

// Proposer calculates and submits state commitments to L1.
type Proposer struct {
	config   *Config
	l1Client L1Client

	// Pending outputs
	pendingOutputs []*state.Output
	pendingMux     sync.RWMutex

	// Submitted outputs
	submittedOutputs map[uint64]*state.Output
	submittedMux     sync.RWMutex

	// Active disputes we're defending
	activeDisputes map[uint64]common.Address
	disputesMux    sync.RWMutex

	// Control
	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup

	// Metrics
	submittedCount uint64
	defenseCount   uint64
}

// New creates a new proposer.
func New(config *Config, l1Client L1Client) *Proposer {
	if config == nil {
		config = DefaultConfig()
	}

	return &Proposer{
		config:           config,
		l1Client:         l1Client,
		pendingOutputs:   make([]*state.Output, 0),
		submittedOutputs: make(map[uint64]*state.Output),
		activeDisputes:   make(map[uint64]common.Address),
	}
}

// Start starts the proposer.
func (p *Proposer) Start(ctx context.Context) error {
	p.ctx, p.cancel = context.WithCancel(ctx)

	p.wg.Add(1)
	go p.submitLoop()

	if p.config.DefenseEnabled {
		p.wg.Add(1)
		go p.defenseLoop()
	}

	return nil
}

// Stop stops the proposer.
func (p *Proposer) Stop() {
	if p.cancel != nil {
		p.cancel()
	}
	p.wg.Wait()
}

// submitLoop periodically submits outputs to L1.
func (p *Proposer) submitLoop() {
	defer p.wg.Done()

	ticker := time.NewTicker(p.config.SubmitInterval)
	defer ticker.Stop()

	for {
		select {
		case <-p.ctx.Done():
			return
		case <-ticker.C:
			p.submitPendingOutputs()
		}
	}
}

// defenseLoop monitors for challenges and defends them.
func (p *Proposer) defenseLoop() {
	defer p.wg.Done()

	ticker := time.NewTicker(p.config.DefenseInterval)
	defer ticker.Stop()

	for {
		select {
		case <-p.ctx.Done():
			return
		case <-ticker.C:
			p.checkAndDefend()
		}
	}
}

// checkAndDefend checks for active disputes and defends them.
func (p *Proposer) checkAndDefend() {
	if p.l1Client == nil {
		return
	}

	// Check all submitted outputs for disputes
	p.submittedMux.RLock()
	outputs := make([]*state.Output, 0, len(p.submittedOutputs))
	for _, output := range p.submittedOutputs {
		outputs = append(outputs, output)
	}
	p.submittedMux.RUnlock()

	for _, output := range outputs {
		hasDispute, err := p.l1Client.HasActiveDispute(p.ctx, output.BatchIndex)
		if err != nil {
			continue
		}

		if hasDispute {
			p.handleDispute(output)
		}
	}

	// Check active disputes for resolution
	p.disputesMux.RLock()
	disputes := make(map[uint64]common.Address)
	for k, v := range p.activeDisputes {
		disputes[k] = v
	}
	p.disputesMux.RUnlock()

	for batchIndex, gameAddr := range disputes {
		p.tryResolve(batchIndex, gameAddr)
	}
}

// handleDispute handles a dispute on one of our outputs.
func (p *Proposer) handleDispute(output *state.Output) {
	batchIndex := output.BatchIndex

	// Already handling this dispute?
	p.disputesMux.RLock()
	_, exists := p.activeDisputes[batchIndex]
	p.disputesMux.RUnlock()

	if exists {
		// Already tracking, make defense moves
		p.makeDefenseMove(batchIndex)
		return
	}

	log.Printf("[Proposer] Detected dispute for batch %d - starting defense", batchIndex)

	// In a real implementation, we would get the game address from L1
	// For now, we track it as a dispute we need to defend
	p.disputesMux.Lock()
	p.activeDisputes[batchIndex] = common.Address{} // Will be filled in real implementation
	p.disputesMux.Unlock()
}

// makeDefenseMove makes a defense move in the dispute game.
func (p *Proposer) makeDefenseMove(batchIndex uint64) {
	output := p.GetOutput(batchIndex)
	if output == nil {
		return
	}

	p.disputesMux.RLock()
	gameAddr := p.activeDisputes[batchIndex]
	p.disputesMux.RUnlock()

	if gameAddr == (common.Address{}) {
		return
	}

	// Get claim count to determine what move to make
	claimCount, err := p.l1Client.GetClaimCount(p.ctx, gameAddr)
	if err != nil {
		return
	}

	// If there are claims to counter, make a defense move
	if claimCount > 1 {
		// Defend the last claim with our correct root
		parentIndex := claimCount - 1
		claim := output.MPTRoot

		log.Printf("[Proposer] Defending batch %d at claim %d with root %x",
			batchIndex, parentIndex, claim[:8])

		if err := p.l1Client.Defend(p.ctx, gameAddr, parentIndex, claim); err != nil {
			log.Printf("[Proposer] Defense failed for batch %d: %v", batchIndex, err)
		} else {
			p.defenseCount++
		}
	}
}

// tryResolve tries to resolve a dispute game.
func (p *Proposer) tryResolve(batchIndex uint64, gameAddr common.Address) {
	if gameAddr == (common.Address{}) {
		return
	}

	canResolve, err := p.l1Client.CanResolve(p.ctx, gameAddr)
	if err != nil || !canResolve {
		return
	}

	log.Printf("[Proposer] Resolving dispute for batch %d...", batchIndex)

	if err := p.l1Client.Resolve(p.ctx, gameAddr); err != nil {
		log.Printf("[Proposer] Failed to resolve dispute: %v", err)
		return
	}

	// Remove from active disputes
	p.disputesMux.Lock()
	delete(p.activeDisputes, batchIndex)
	p.disputesMux.Unlock()

	log.Printf("[Proposer] ✓ Dispute for batch %d resolved", batchIndex)
}

// submitPendingOutputs submits all pending outputs.
func (p *Proposer) submitPendingOutputs() {
	p.pendingMux.Lock()
	outputs := p.pendingOutputs
	p.pendingOutputs = make([]*state.Output, 0)
	p.pendingMux.Unlock()

	for _, output := range outputs {
		if err := p.submitOutput(output); err != nil {
			// Re-add failed output
			p.pendingMux.Lock()
			p.pendingOutputs = append([]*state.Output{output}, p.pendingOutputs...)
			p.pendingMux.Unlock()
			return
		}
	}
}

// submitOutput submits a single output to L1.
func (p *Proposer) submitOutput(output *state.Output) error {
	log.Printf("[Proposer] Submitting output for batch %d (stateHash=%x, mptRoot=%x)",
		output.BatchIndex, output.FinalStateHash[:8], output.MPTRoot[:8])

	// Submit to L1
	if p.l1Client != nil {
		if err := p.l1Client.SubmitOutput(p.ctx, output); err != nil {
			log.Printf("[Proposer] Failed to submit output %d to L1: %v", output.BatchIndex, err)
			return err
		}
		log.Printf("[Proposer] ✓ Output %d submitted to L1", output.BatchIndex)
	} else {
		log.Printf("[Proposer] ✓ Output %d processed (no L1 client)", output.BatchIndex)
	}

	// Track submitted output
	p.submittedMux.Lock()
	p.submittedOutputs[output.BatchIndex] = output
	p.submittedMux.Unlock()

	p.submittedCount++
	return nil
}

// AddBatch processes a batch and creates an output for submission.
func (p *Proposer) AddBatch(batch *state.Batch) {
	output := state.NewOutput(batch, uint64(time.Now().Unix()))

	p.pendingMux.Lock()
	p.pendingOutputs = append(p.pendingOutputs, output)
	p.pendingMux.Unlock()
}

// GetOutput returns a submitted output by batch index.
func (p *Proposer) GetOutput(batchIndex uint64) *state.Output {
	p.submittedMux.RLock()
	defer p.submittedMux.RUnlock()
	return p.submittedOutputs[batchIndex]
}

// PendingCount returns the number of pending outputs.
func (p *Proposer) PendingCount() int {
	p.pendingMux.RLock()
	defer p.pendingMux.RUnlock()
	return len(p.pendingOutputs)
}

// SubmittedCount returns the number of submitted outputs.
func (p *Proposer) SubmittedCount() uint64 {
	return p.submittedCount
}

// DefenseCount returns the number of defense moves made.
func (p *Proposer) DefenseCount() uint64 {
	return p.defenseCount
}

// ForceSubmit forces immediate submission of pending outputs.
func (p *Proposer) ForceSubmit() {
	p.submitPendingOutputs()
}

// LatestSubmittedOutput returns the latest submitted output.
func (p *Proposer) LatestSubmittedOutput() *state.Output {
	p.submittedMux.RLock()
	defer p.submittedMux.RUnlock()

	var latest *state.Output
	var maxIndex uint64 = 0

	for idx, output := range p.submittedOutputs {
		if idx > maxIndex {
			maxIndex = idx
			latest = output
		}
	}

	return latest
}

// GetStats returns proposer statistics.
func (p *Proposer) GetStats() map[string]interface{} {
	p.disputesMux.RLock()
	activeDisputes := len(p.activeDisputes)
	p.disputesMux.RUnlock()

	return map[string]interface{}{
		"submitted_count": p.submittedCount,
		"defense_count":   p.defenseCount,
		"pending_count":   p.PendingCount(),
		"active_disputes": activeDisputes,
		"defense_enabled": p.config.DefenseEnabled,
	}
}
