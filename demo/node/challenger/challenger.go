// Package challenger implements the DEMO challenger service.
// Challenger monitors L2 blocks, auto-challenges every N blocks, and participates in bisection games.
package challenger

import (
	"context"
	"errors"
	"log"
	"os"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/ethereum-optimism/optimism/demo/core/mpt"
	"github.com/ethereum-optimism/optimism/demo/core/state"
	"github.com/ethereum-optimism/optimism/demo/core/types"
	"github.com/ethereum-optimism/optimism/demo/node/cannon"
)

// Errors
var (
	ErrCannonNotInitialized = errors.New("cannon not initialized")
)

// GameStatus represents the status of a dispute game.
type GameStatus uint8

const (
	GameStatusInProgress     GameStatus = 0
	GameStatusChallengerWins GameStatus = 1
	GameStatusDefenderWins   GameStatus = 2
)

// DisputeGame represents a dispute game on L1.
type DisputeGame struct {
	GameAddress types.Address
	GameID      types.Hash
	BatchIndex  uint64
	ClaimedRoot types.Hash // The MPT root being disputed
	Status      GameStatus
	Challenger  types.Address
	StartTime   uint64
	ClaimCount  uint64

	// Bisection tracking
	CurrentStep uint64 // Current step being disputed in bisection
	StepLow     uint64 // Lower bound of disputed step range
	StepHigh    uint64 // Upper bound of disputed step range
}

// Claim represents a claim in the bisection game.
type Claim struct {
	Index       uint64
	Value       types.Hash
	Parent      uint64
	Position    uint64 // Position in the game tree (gindex)
	Claimant    types.Address
	CounteredBy types.Address
}

// L1Client interface for dispute game interactions.
type L1Client interface {
	// Game management
	CreateDisputeGame(ctx context.Context, batchIndex uint64, claimedRoot types.Hash) (common.Address, error)
	GetDisputeGame(ctx context.Context, gameAddr common.Address) (*DisputeGame, error)
	GetActiveGames(ctx context.Context) ([]*DisputeGame, error)
	HasActiveDispute(ctx context.Context, batchIndex uint64) (bool, error)
	GetOutputMPTRoot(ctx context.Context, batchIndex uint64) (types.Hash, error)
	GetLatestOutputIndex() (uint64, error)

	// Bisection actions
	Attack(ctx context.Context, gameAddr common.Address, parentIndex uint64, claim types.Hash) error
	Defend(ctx context.Context, gameAddr common.Address, parentIndex uint64, claim types.Hash) error

	// Resolution
	Step(ctx context.Context, gameAddr common.Address, claimIndex uint64, stateData, proof []byte, preStateHash, postStateHash common.Hash) error
	Resolve(ctx context.Context, gameAddr common.Address) error
	CanResolve(ctx context.Context, gameAddr common.Address) (bool, error)
	GetClaimCount(ctx context.Context, gameAddr common.Address) (uint64, error)
}

// StateProvider provides state data for challenges.
type StateProvider interface {
	GetVerifiableState(batchIndex uint64) (*state.VerifiableState, error)
	GenerateProof(batchIndex uint64, key []byte) (*mpt.Proof, error)
	ComputeMPTRoot(batchIndex uint64) (types.Hash, error)
}

// Config holds challenger configuration.
type Config struct {
	PollInterval       time.Duration
	ChallengeEveryN    uint64 // Challenge every N outputs/batches (e.g., 100)
	Honest             bool   // If true, defend valid claims; if false, attack everything
	AutoChallenge      bool   // If true, automatically challenge at intervals
	DisputeGameFactory types.Address
	// Cannon configuration
	ProgramPath string // Path to program.elf
	WorkDir     string // Working directory for cannon
	CannonPath  string // Path to cannon binary (for local mode)
	DockerImage string // Docker image for cannon (for docker mode)
}

// DefaultConfig returns default challenger config.
func DefaultConfig() *Config {
	return &Config{
		PollInterval:    5 * time.Second, // Fast polling for testing
		ChallengeEveryN: 100,             // Challenge every 100 outputs/batches
		Honest:          true,
		AutoChallenge:   true,
		ProgramPath:     "./bin/program.elf",
		WorkDir:         "./cannon-work",
		CannonPath:      "", // Empty = use Docker mode
		DockerImage:     "cannon-runner",
	}
}

// Challenger monitors and participates in dispute games.
type Challenger struct {
	config        *Config
	l1Client      L1Client
	stateProvider StateProvider
	address       types.Address

	// Cannon executor for real MIPS execution
	cannonExecutor   *cannon.CannonExecutor
	preimageServer   *cannon.PreimageServer
	initialStatePath string // Path to initial cannon state

	// Active games being monitored
	activeGames map[common.Address]*DisputeGame
	gamesMux    sync.RWMutex

	// Track last challenged output
	lastChallengedIndex uint64

	// Control
	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup
}

// New creates a new challenger.
func New(config *Config, l1Client L1Client, stateProvider StateProvider, address types.Address) *Challenger {
	if config == nil {
		config = DefaultConfig()
	}

	// Create work directory
	if err := os.MkdirAll(config.WorkDir, 0755); err != nil {
		log.Printf("[Challenger] Warning: failed to create work dir: %v", err)
	}

	// Initialize preimage server
	preimageServer := cannon.NewPreimageServer(nil)

	// Initialize cannon executor based on configuration
	var cannonExecutor *cannon.CannonExecutor
	if config.CannonPath != "" {
		// Local mode - use cannon binary directly
		log.Printf("[Challenger] Using local cannon mode: %s", config.CannonPath)
		cannonExecutor = cannon.NewCannonExecutor(&cannon.ExecutorConfig{
			Mode:       cannon.ModeLocal,
			CannonPath: config.CannonPath,
			WorkDir:    config.WorkDir,
			ELFPath:    config.ProgramPath,
		}, preimageServer, nil)
	} else {
		// Docker mode for macOS compatibility
		log.Printf("[Challenger] Using Docker cannon mode")
		cannonExecutor = cannon.NewDockerCannonExecutor(
			config.WorkDir,
			config.ProgramPath,
			preimageServer,
			nil,
		)
	}

	return &Challenger{
		config:              config,
		l1Client:            l1Client,
		stateProvider:       stateProvider,
		address:             address,
		cannonExecutor:      cannonExecutor,
		preimageServer:      preimageServer,
		activeGames:         make(map[common.Address]*DisputeGame),
		lastChallengedIndex: 0,
	}
}

// Start starts the challenger.
func (c *Challenger) Start(ctx context.Context) error {
	c.ctx, c.cancel = context.WithCancel(ctx)

	log.Printf("[Challenger] Starting (ChallengeEveryN=%d, AutoChallenge=%v)",
		c.config.ChallengeEveryN, c.config.AutoChallenge)

	// Load ELF and create initial state
	if c.config.ProgramPath != "" {
		statePath, err := c.cannonExecutor.LoadELF(ctx)
		if err != nil {
			log.Printf("[Challenger] Warning: failed to load ELF: %v", err)
		} else {
			c.initialStatePath = statePath
			log.Printf("[Challenger] Loaded program ELF, initial state: %s", statePath)
		}
	}

	c.wg.Add(1)
	go c.mainLoop()

	return nil
}

// Stop stops the challenger.
func (c *Challenger) Stop() {
	if c.cancel != nil {
		c.cancel()
	}
	c.wg.Wait()
}

// mainLoop is the main challenger loop.
func (c *Challenger) mainLoop() {
	defer c.wg.Done()

	ticker := time.NewTicker(c.config.PollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-c.ctx.Done():
			return
		case <-ticker.C:
			c.tick()
		}
	}
}

// tick executes one challenger cycle.
func (c *Challenger) tick() {
	if c.l1Client == nil {
		return
	}

	// 1. Check for auto-challenge opportunity
	if c.config.AutoChallenge {
		c.checkAutoChallenge()
	}

	// 2. Process active games (bisection, resolution)
	c.processActiveGames()
}

// checkAutoChallenge checks if we should create a new challenge.
func (c *Challenger) checkAutoChallenge() {
	ctx := c.ctx

	// Get latest output index from L1
	latestIndex, err := c.l1Client.GetLatestOutputIndex()
	if err != nil || latestIndex == 0 {
		return
	}

	// Check if we should challenge (every N outputs)
	targetIndex := ((latestIndex - 1) / c.config.ChallengeEveryN) * c.config.ChallengeEveryN
	if targetIndex == 0 || targetIndex <= c.lastChallengedIndex {
		return
	}

	// Check if already disputed
	hasDispute, err := c.l1Client.HasActiveDispute(ctx, targetIndex)
	if err != nil || hasDispute {
		// Update lastChallengedIndex to skip this one and move to next target
		c.lastChallengedIndex = targetIndex
		return
	}

	log.Printf("[Challenger] Auto-challenge triggered for output index %d (latest: %d)", targetIndex, latestIndex)

	// Get the MPT root from L1
	proposedRoot, err := c.l1Client.GetOutputMPTRoot(ctx, targetIndex)
	if err != nil {
		log.Printf("[Challenger] Failed to get MPT root for output %d: %v", targetIndex, err)
		return
	}

	if proposedRoot == (types.Hash{}) {
		log.Printf("[Challenger] Output %d has zero MPT root, skipping", targetIndex)
		return
	}

	// Compute the correct root locally
	correctRoot, err := c.computeCorrectRoot(targetIndex)
	if err != nil {
		log.Printf("[Challenger] Failed to compute local root for output %d: %v", targetIndex, err)
		// For testing, create a fake "incorrect" root to trigger challenge
		correctRoot = types.Keccak256([]byte("test-challenge"), types.Uint64ToBytes(targetIndex))
	}

	// Create the dispute game
	// For testing: we intentionally use a different root to trigger the game
	claimedRoot := correctRoot
	if claimedRoot == proposedRoot {
		// If roots match, flip one bit to create a dispute (for testing)
		claimedRoot[0] ^= 0xFF
	}

	log.Printf("[Challenger] Creating dispute game: output=%d proposed=%x claimed=%x",
		targetIndex, proposedRoot[:8], claimedRoot[:8])

	gameAddr, err := c.l1Client.CreateDisputeGame(ctx, targetIndex, claimedRoot)
	if err != nil {
		log.Printf("[Challenger] Failed to create dispute game: %v", err)
		return
	}

	log.Printf("[Challenger] ✓ Dispute game created at %s for output %d", gameAddr.Hex()[:10], targetIndex)

	// Track the game with bisection range initialized
	// For demo program, max steps is around 100k-200k, use smaller range for faster bisection
	const maxSteps = uint64(1024) // Use power of 2 for clean bisection, ~10 rounds to converge
	c.gamesMux.Lock()
	c.activeGames[gameAddr] = &DisputeGame{
		GameAddress: types.Address(gameAddr),
		BatchIndex:  targetIndex,
		ClaimedRoot: claimedRoot,
		Status:      GameStatusInProgress,
		StepLow:     0,
		StepHigh:    maxSteps,
		CurrentStep: maxSteps / 2,
	}
	c.lastChallengedIndex = targetIndex
	c.gamesMux.Unlock()
}

// computeCorrectRoot computes the correct MPT root for a batch.
func (c *Challenger) computeCorrectRoot(batchIndex uint64) (types.Hash, error) {
	if c.stateProvider == nil {
		return types.Hash{}, nil
	}

	vs, err := c.stateProvider.GetVerifiableState(batchIndex)
	if err != nil {
		return types.Hash{}, err
	}

	return vs.MPTRoot(), nil
}

// processActiveGames processes all active dispute games.
func (c *Challenger) processActiveGames() {
	c.gamesMux.RLock()
	games := make([]*DisputeGame, 0, len(c.activeGames))
	for _, game := range c.activeGames {
		games = append(games, game)
	}
	c.gamesMux.RUnlock()

	for _, game := range games {
		c.processGame(game)
	}
}

// processGame processes a single dispute game.
func (c *Challenger) processGame(game *DisputeGame) {
	ctx := c.ctx
	gameAddr := common.Address(game.GameAddress)

	// Get current game status
	currentGame, err := c.l1Client.GetDisputeGame(ctx, gameAddr)
	if err != nil {
		return
	}

	// If game is resolved, remove from active list
	if currentGame != nil && currentGame.Status != 0 {
		log.Printf("[Challenger] Game %s resolved with status %d", gameAddr.Hex()[:10], currentGame.Status)
		c.gamesMux.Lock()
		delete(c.activeGames, gameAddr)
		c.gamesMux.Unlock()
		return
	}

	// Get claim count
	claimCount, err := c.l1Client.GetClaimCount(ctx, gameAddr)
	if err != nil {
		return
	}

	// If we haven't made any moves yet (only root claim), make the first attack
	if claimCount == 1 {
		c.makeFirstMove(game, gameAddr)
		return
	}

	// Check if we can resolve
	canResolve, err := c.l1Client.CanResolve(ctx, gameAddr)
	if err == nil && canResolve {
		log.Printf("[Challenger] Resolving game %s...", gameAddr.Hex()[:10])
		if err := c.l1Client.Resolve(ctx, gameAddr); err != nil {
			log.Printf("[Challenger] Failed to resolve game: %v", err)
		}
		return
	}

	// Continue bisection if needed
	c.continueBisection(game, gameAddr, claimCount)
}

// makeFirstMove makes the first attack move on a game.
func (c *Challenger) makeFirstMove(game *DisputeGame, gameAddr common.Address) {
	ctx := c.ctx

	// Attack the root claim with our claimed root
	// Position 0 = root claim (proposer's claim)
	claim := game.ClaimedRoot
	log.Printf("[Challenger] Making first attack on game %s with claim %x", gameAddr.Hex()[:10], claim[:8])

	if err := c.l1Client.Attack(ctx, gameAddr, 0, claim); err != nil {
		log.Printf("[Challenger] Failed to make first attack: %v", err)
	}
}

// continueBisection continues the bisection game using real Cannon execution.
// Uses binary search to find the divergent step efficiently.
func (c *Challenger) continueBisection(game *DisputeGame, gameAddr common.Address, claimCount uint64) {
	ctx := c.ctx

	log.Printf("[Challenger] Game %s has %d claims, continuing bisection with Cannon...", gameAddr.Hex()[:10], claimCount)

	// Check if cannon is initialized
	if c.initialStatePath == "" {
		log.Printf("[Challenger] Cannon not initialized, using simple bisection")
		c.simpleBisection(game, gameAddr, claimCount)
		return
	}

	// Binary search parameters
	// MAX_GAME_DEPTH determines how many bisection rounds are needed
	// For a program with N steps, we need log2(N) rounds
	// With maxSteps=1024, we need log2(1024)=10 rounds
	const maxGameDepth = 10 // Supports up to 2^10 = 1024 steps for demo

	parentIndex := claimCount - 1
	depth := parentIndex // Current depth in the game tree

	// Check if we've reached max depth (time for final step proof)
	if depth >= maxGameDepth {
		c.submitStepProof(game, gameAddr, claimCount)
		return
	}

	// Update bisection range based on depth
	rangeSize := game.StepHigh - game.StepLow
	midpoint := game.StepLow + rangeSize/2

	// For demo: narrow down the range each round
	// In reality, we'd compare our state with the opponent's claimed state
	if depth%2 == 0 {
		// Go to lower half
		game.StepHigh = midpoint
	} else {
		// Go to upper half
		game.StepLow = midpoint
	}

	// The step to check is the midpoint of the current range
	stepToCheck := game.StepLow + (game.StepHigh-game.StepLow)/2
	game.CurrentStep = stepToCheck

	// Run cannon to the step and get the state hash
	log.Printf("[Challenger] Bisection depth=%d, checking step %d (range [%d, %d])...",
		depth, stepToCheck, game.StepLow, game.StepHigh)
	result, err := c.cannonExecutor.RunToStep(ctx, c.initialStatePath, stepToCheck)
	if err != nil {
		log.Printf("[Challenger] Cannon execution failed: %v, falling back to simple bisection", err)
		c.simpleBisection(game, gameAddr, claimCount)
		return
	}

	// Get the state hash at this step
	stateHash, err := c.cannonExecutor.GetStateHash(ctx, result.FinalState)
	if err != nil {
		log.Printf("[Challenger] Failed to get state hash: %v", err)
		c.simpleBisection(game, gameAddr, claimCount)
		return
	}

	log.Printf("[Challenger] Cannon state at step %d: %s", stepToCheck, common.Hash(stateHash).Hex()[:18])

	// Use the cannon-computed state hash as our claim
	claim := types.Hash(stateHash)

	// Alternate between attack and defend based on depth
	if parentIndex%2 == 0 {
		if err := c.l1Client.Attack(ctx, gameAddr, parentIndex, claim); err != nil {
			log.Printf("[Challenger] Failed to attack at index %d: %v", parentIndex, err)
		}
	} else {
		if err := c.l1Client.Defend(ctx, gameAddr, parentIndex, claim); err != nil {
			log.Printf("[Challenger] Failed to defend at index %d: %v", parentIndex, err)
		}
	}
}

// submitStepProof generates and submits the final step proof when bisection reaches max depth.
func (c *Challenger) submitStepProof(game *DisputeGame, gameAddr common.Address, claimCount uint64) {
	ctx := c.ctx

	// In bisection, when we reach max depth:
	// - parent claim (index N-1) represents state at step X (game.StepLow)
	// - current claim (index N) represents state at step X+1 (game.StepLow + 1)
	// We need to prove the transition from step X to step X+1
	// So we generate proof at step X (game.StepLow), which gives us:
	// - pre = state at step X
	// - post = state at step X+1 (after executing one instruction)
	disputedStep := game.StepLow
	if disputedStep == 0 {
		disputedStep = 1 // Can't prove step 0
	}

	log.Printf("[Challenger] Reached max depth, generating step proof for step %d → %d (range [%d, %d])...",
		disputedStep, disputedStep+1, game.StepLow, game.StepHigh)

	// Generate the proof using cannon
	proof, err := c.cannonExecutor.GenerateProofAt(ctx, c.initialStatePath, disputedStep)
	if err != nil {
		log.Printf("[Challenger] Failed to generate step proof: %v", err)
		log.Printf("[Challenger] Game will be resolved by timeout instead")
		return
	}

	log.Printf("[Challenger] Generated proof for step %d: pre=%s post=%s",
		proof.Step, proof.Pre.Hex()[:10], proof.Post.Hex()[:10])

	// Submit the step proof to L1
	// The contract expects: claimIndex, stateData, proof, preStateHash, postStateHash
	// The MIPS contract will verify that keccak256(stateData) == preStateHash
	lastClaimIndex := claimCount - 1
	err = c.l1Client.Step(ctx, gameAddr, lastClaimIndex, proof.StateData, proof.ProofData, proof.Pre, proof.Post)
	if err != nil {
		log.Printf("[Challenger] Failed to submit step proof: %v", err)
		return
	}

	log.Printf("[Challenger] ✓ Step proof submitted for game %s", gameAddr.Hex()[:10])

	// Now resolve the game
	log.Printf("[Challenger] Resolving game %s...", gameAddr.Hex()[:10])
	if err := c.l1Client.Resolve(ctx, gameAddr); err != nil {
		log.Printf("[Challenger] Failed to resolve game: %v", err)
		return
	}

	log.Printf("[Challenger] ✓ Game %s resolved!", gameAddr.Hex()[:10])

	// Remove from active games
	c.gamesMux.Lock()
	delete(c.activeGames, gameAddr)
	c.gamesMux.Unlock()
}

// simpleBisection is the fallback simple bisection without cannon.
func (c *Challenger) simpleBisection(game *DisputeGame, gameAddr common.Address, claimCount uint64) {
	parentIndex := claimCount - 1
	claim := types.Keccak256(game.ClaimedRoot[:], types.Uint64ToBytes(parentIndex))

	if parentIndex%2 == 0 {
		if err := c.l1Client.Attack(c.ctx, gameAddr, parentIndex, claim); err != nil {
			log.Printf("[Challenger] Failed to attack at index %d: %v", parentIndex, err)
		}
	} else {
		if err := c.l1Client.Defend(c.ctx, gameAddr, parentIndex, claim); err != nil {
			log.Printf("[Challenger] Failed to defend at index %d: %v", parentIndex, err)
		}
	}
}

// CreateChallenge manually creates a dispute game.
func (c *Challenger) CreateChallenge(batchIndex uint64, claimedRoot types.Hash) (common.Address, error) {
	return c.l1Client.CreateDisputeGame(c.ctx, batchIndex, claimedRoot)
}

// ProvideStepProof provides the final step proof.
// Deprecated: Use submitStepProof with Cannon instead.
func (c *Challenger) ProvideStepProof(gameAddr common.Address, batchIndex uint64, key []byte) error {
	proof, err := c.stateProvider.GenerateProof(batchIndex, key)
	if err != nil {
		return err
	}

	// Note: This uses the old state provider, not Cannon.
	// For the new MIPS step function, we need proper pre/post state hashes.
	// Using empty hashes as placeholders since this function is deprecated.
	return c.l1Client.Step(c.ctx, gameAddr, 0, key, proof.ToBytes(), common.Hash{}, common.Hash{})
}

// GenerateCannonStepProof generates a step proof using the real cannon binary.
func (c *Challenger) GenerateCannonStepProof(
	ctx context.Context,
	step uint64,
) (*cannon.Proof, error) {
	if c.initialStatePath == "" {
		return nil, ErrCannonNotInitialized
	}
	return c.cannonExecutor.GenerateProofAt(ctx, c.initialStatePath, step)
}

// FindDivergentStep finds the first step where local and claimed states diverge.
func (c *Challenger) FindDivergentStep(
	ctx context.Context,
	claimedFinalHash common.Hash,
	maxSteps uint64,
) (uint64, *cannon.Proof, error) {
	if c.initialStatePath == "" {
		return 0, nil, ErrCannonNotInitialized
	}
	return c.cannonExecutor.FindDivergentStep(ctx, c.initialStatePath, claimedFinalHash, maxSteps)
}

// AddPreimage adds a preimage to the server.
func (c *Challenger) AddPreimage(data []byte) common.Hash {
	return c.preimageServer.AddPreimage(data)
}

// AddLocalPreimage adds local data to the server.
func (c *Challenger) AddLocalPreimage(ident uint64, data []byte) common.Hash {
	return c.preimageServer.AddLocalData(ident, data)
}

// RunCannonToCompletion runs cannon until the program exits.
func (c *Challenger) RunCannonToCompletion(ctx context.Context) (*cannon.RunResult, error) {
	if c.initialStatePath == "" {
		return nil, ErrCannonNotInitialized
	}
	return c.cannonExecutor.RunToCompletion(ctx, c.initialStatePath)
}

// GetActiveGames returns all active games.
func (c *Challenger) GetActiveGames() []*DisputeGame {
	c.gamesMux.RLock()
	defer c.gamesMux.RUnlock()

	games := make([]*DisputeGame, 0, len(c.activeGames))
	for _, game := range c.activeGames {
		games = append(games, game)
	}
	return games
}

// GetStats returns challenger statistics.
func (c *Challenger) GetStats() map[string]interface{} {
	c.gamesMux.RLock()
	defer c.gamesMux.RUnlock()

	return map[string]interface{}{
		"active_games":           len(c.activeGames),
		"last_challenged_index":  c.lastChallengedIndex,
		"challenge_every_n":      c.config.ChallengeEveryN,
		"auto_challenge_enabled": c.config.AutoChallenge,
	}
}
