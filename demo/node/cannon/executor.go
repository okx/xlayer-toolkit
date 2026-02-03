package cannon

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
)

// Proof represents a cannon proof output.
type Proof struct {
	Step uint64 `json:"step"`

	Pre  common.Hash `json:"pre"`
	Post common.Hash `json:"post"`

	StateData hexutil.Bytes `json:"state-data"`
	ProofData hexutil.Bytes `json:"proof-data"`

	OracleKey    hexutil.Bytes `json:"oracle-key,omitempty"`
	OracleValue  hexutil.Bytes `json:"oracle-value,omitempty"`
	OracleOffset uint64        `json:"oracle-offset,omitempty"`
}

// ExecutorMode specifies how to run cannon.
type ExecutorMode string

const (
	// ModeLocal runs cannon as a local binary.
	ModeLocal ExecutorMode = "local"
	// ModeDocker runs cannon in a Docker container.
	ModeDocker ExecutorMode = "docker"
)

// CannonExecutor executes cannon to generate proofs.
type CannonExecutor struct {
	mode           ExecutorMode
	cannonPath     string // For local mode: path to cannon binary
	dockerImage    string // For docker mode: image name
	workDir        string // Host work directory
	containerWork  string // Container work directory
	elfPath        string // Path to program.elf
	vmType         string // VM type for cannon
	metaPath       string // Path to meta.json (set after LoadELF)
	preimageServer *PreimageServer
	logger         *log.Logger
}

// ExecutorConfig contains configuration for CannonExecutor.
type ExecutorConfig struct {
	Mode          ExecutorMode
	CannonPath    string // For local mode
	DockerImage   string // For docker mode (default: cannon-runner)
	WorkDir       string // Host work directory
	ELFPath       string // Path to program.elf
	ContainerWork string // Container work directory (default: /work)
	VMType        string // VM type (default: multithreaded64-5)
}

// NewCannonExecutor creates a new cannon executor.
func NewCannonExecutor(config *ExecutorConfig, preimageServer *PreimageServer, logger *log.Logger) *CannonExecutor {
	if logger == nil {
		logger = log.New(os.Stderr, "[CannonExecutor] ", log.LstdFlags)
	}

	mode := config.Mode
	if mode == "" {
		mode = ModeDocker // Default to Docker for macOS compatibility
	}

	dockerImage := config.DockerImage
	if dockerImage == "" {
		dockerImage = "cannon-runner"
	}

	containerWork := config.ContainerWork
	if containerWork == "" {
		containerWork = "/work"
	}

	vmType := config.VMType
	if vmType == "" {
		vmType = "multithreaded64-5" // Default for Go MIPS64 binaries
	}

	return &CannonExecutor{
		mode:           mode,
		cannonPath:     config.CannonPath,
		dockerImage:    dockerImage,
		workDir:        config.WorkDir,
		containerWork:  containerWork,
		elfPath:        config.ELFPath,
		vmType:         vmType,
		preimageServer: preimageServer,
		logger:         logger,
	}
}

// NewDockerCannonExecutor creates a Docker-based cannon executor.
func NewDockerCannonExecutor(workDir, elfPath string, preimageServer *PreimageServer, logger *log.Logger) *CannonExecutor {
	return NewCannonExecutor(&ExecutorConfig{
		Mode:        ModeDocker,
		DockerImage: "cannon-runner",
		WorkDir:     workDir,
		ELFPath:     elfPath,
	}, preimageServer, logger)
}

// runCannon executes cannon with the given arguments.
func (e *CannonExecutor) runCannon(ctx context.Context, args ...string) ([]byte, error) {
	var cmd *exec.Cmd

	switch e.mode {
	case ModeLocal:
		cmd = exec.CommandContext(ctx, e.cannonPath, args...)
	case ModeDocker:
		// Build docker run command
		dockerArgs := []string{
			"run", "--rm",
			"-v", fmt.Sprintf("%s:%s", e.workDir, e.containerWork),
		}

		// Mount ELF directory if specified
		if e.elfPath != "" {
			elfDir := filepath.Dir(e.elfPath)
			dockerArgs = append(dockerArgs, "-v", fmt.Sprintf("%s:/app/bin:ro", elfDir))
		}

		dockerArgs = append(dockerArgs, "-w", e.containerWork)
		dockerArgs = append(dockerArgs, e.dockerImage)
		dockerArgs = append(dockerArgs, args...)

		cmd = exec.CommandContext(ctx, "docker", dockerArgs...)
	default:
		return nil, fmt.Errorf("unknown executor mode: %s", e.mode)
	}

	e.logger.Printf("Running: %s", strings.Join(cmd.Args, " "))

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("cannon failed: %w\nstderr: %s", err, stderr.String())
	}

	return stdout.Bytes(), nil
}

// translatePath converts a host path to a container path for Docker mode.
func (e *CannonExecutor) translatePath(hostPath string) string {
	if e.mode == ModeLocal {
		return hostPath
	}

	// For Docker mode, translate paths
	if strings.HasPrefix(hostPath, e.workDir) {
		return strings.Replace(hostPath, e.workDir, e.containerWork, 1)
	}

	// Handle ELF path
	if e.elfPath != "" {
		elfDir := filepath.Dir(e.elfPath)
		if strings.HasPrefix(hostPath, elfDir) {
			return strings.Replace(hostPath, elfDir, "/app/bin", 1)
		}
	}

	return hostPath
}

// LoadELF loads an ELF file and creates the initial state.
func (e *CannonExecutor) LoadELF(ctx context.Context) (string, error) {
	if err := os.MkdirAll(e.workDir, 0755); err != nil {
		return "", fmt.Errorf("failed to create work directory: %w", err)
	}

	statePath := filepath.Join(e.workDir, "state.bin.gz")
	metaPath := filepath.Join(e.workDir, "meta.json")

	elfPath := e.translatePath(e.elfPath)
	statePathContainer := e.translatePath(statePath)
	metaPathContainer := e.translatePath(metaPath)

	e.logger.Printf("Loading ELF: %s (type: %s)", e.elfPath, e.vmType)

	_, err := e.runCannon(ctx,
		"load-elf",
		"--type", e.vmType,
		"--path", elfPath,
		"--out", statePathContainer,
		"--meta", metaPathContainer,
	)
	if err != nil {
		return "", err
	}

	// Save meta path for later use in Run
	e.metaPath = metaPath

	e.logger.Printf("ELF loaded, state saved to: %s", statePath)
	return statePath, nil
}

// RunConfig contains configuration for running cannon.
type RunConfig struct {
	// InputState is the path to the input state file.
	InputState string
	// OutputState is the path to the output state file (optional).
	OutputState string
	// ProofAt specifies at which step to generate a proof.
	// Use "=N" for exact step, "%N" for every N steps, "never" for no proofs.
	ProofAt string
	// StopAt specifies at which step to stop.
	StopAt string
	// MetaPath is the path to the metadata file (optional).
	MetaPath string
	// InfoAt specifies when to print info (e.g., "%10000" for every 10000 steps).
	InfoAt string
}

// RunResult contains the result of running cannon.
type RunResult struct {
	// FinalState is the path to the final state file.
	FinalState string
	// Proofs contains any generated proofs.
	Proofs []*Proof
	// Exited indicates if the program exited.
	Exited bool
	// ExitCode is the exit code if the program exited.
	ExitCode uint8
	// Steps is the number of steps executed.
	Steps uint64
}

// Run executes cannon with the given configuration.
func (e *CannonExecutor) Run(ctx context.Context, config *RunConfig) (*RunResult, error) {
	if config.InputState == "" {
		return nil, fmt.Errorf("input state is required")
	}

	// Prepare output paths
	outputState := config.OutputState
	if outputState == "" {
		outputState = filepath.Join(e.workDir, "output.bin.gz")
	}

	proofDir := filepath.Join(e.workDir, "proofs")
	// Clean old proofs before generating new ones
	os.RemoveAll(proofDir)
	if err := os.MkdirAll(proofDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create proof directory: %w", err)
	}

	// Build command arguments
	args := []string{"run",
		"--input", e.translatePath(config.InputState),
		"--output", e.translatePath(outputState),
	}

	if config.ProofAt != "" {
		args = append(args, "--proof-at", config.ProofAt)
		args = append(args, "--proof-fmt", e.translatePath(filepath.Join(proofDir, "proof-%d.json")))
	}

	if config.StopAt != "" {
		args = append(args, "--stop-at", config.StopAt)
	}

	// Use configured meta path or fallback to executor's meta path
	metaPath := config.MetaPath
	if metaPath == "" && e.metaPath != "" {
		metaPath = e.metaPath
	}
	if metaPath != "" {
		args = append(args, "--meta", e.translatePath(metaPath))
	}

	if config.InfoAt != "" {
		args = append(args, "--info-at", config.InfoAt)
	}

	startTime := time.Now()
	_, err := e.runCannon(ctx, args...)
	duration := time.Since(startTime)

	e.logger.Printf("Cannon finished in %v", duration)

	if err != nil {
		return nil, err
	}

	// Parse output to get execution info
	result := &RunResult{
		FinalState: outputState,
		Proofs:     make([]*Proof, 0),
	}

	// Load any generated proofs
	proofFiles, _ := filepath.Glob(filepath.Join(proofDir, "proof-*.json"))
	for _, proofFile := range proofFiles {
		proof, err := e.loadProof(proofFile)
		if err != nil {
			e.logger.Printf("Warning: failed to load proof %s: %v", proofFile, err)
			continue
		}
		result.Proofs = append(result.Proofs, proof)
	}

	e.logger.Printf("Loaded %d proofs", len(result.Proofs))

	return result, nil
}

// GenerateProofAt generates a proof at a specific step.
func (e *CannonExecutor) GenerateProofAt(ctx context.Context, inputState string, step uint64) (*Proof, error) {
	config := &RunConfig{
		InputState: inputState,
		ProofAt:    fmt.Sprintf("=%d", step),
		StopAt:     fmt.Sprintf("=%d", step+1),
	}

	result, err := e.Run(ctx, config)
	if err != nil {
		return nil, err
	}

	if len(result.Proofs) == 0 {
		return nil, fmt.Errorf("no proof generated at step %d", step)
	}

	return result.Proofs[0], nil
}

// RunToCompletion runs cannon until the program exits.
func (e *CannonExecutor) RunToCompletion(ctx context.Context, inputState string) (*RunResult, error) {
	config := &RunConfig{
		InputState: inputState,
		ProofAt:    "never",
		InfoAt:     "%10000",
	}

	return e.Run(ctx, config)
}

// RunToStep runs cannon until a specific step.
func (e *CannonExecutor) RunToStep(ctx context.Context, inputState string, step uint64) (*RunResult, error) {
	config := &RunConfig{
		InputState: inputState,
		ProofAt:    "never",
		StopAt:     fmt.Sprintf("=%d", step),
	}

	return e.Run(ctx, config)
}

// GetStateHash reads the state hash from a state file.
func (e *CannonExecutor) GetStateHash(ctx context.Context, statePath string) (common.Hash, error) {
	output, err := e.runCannon(ctx, "witness",
		"--input", e.translatePath(statePath),
	)
	if err != nil {
		return common.Hash{}, err
	}

	// Parse witness output to get state hash
	// The witness command outputs JSON with witnessHash field
	var witness struct {
		WitnessHash common.Hash `json:"witnessHash"`
		Step        uint64      `json:"step"`
		Exited      bool        `json:"exited"`
		ExitCode    uint8       `json:"exitCode"`
	}
	if err := json.Unmarshal(output, &witness); err != nil {
		return common.Hash{}, fmt.Errorf("failed to parse witness output: %w\noutput: %s", err, string(output))
	}

	e.logger.Printf("Witness: step=%d hash=%s exited=%v", witness.Step, witness.WitnessHash.Hex()[:18], witness.Exited)

	return witness.WitnessHash, nil
}

// loadProof loads a proof from a JSON file.
func (e *CannonExecutor) loadProof(path string) (*Proof, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	data, err := io.ReadAll(f)
	if err != nil {
		return nil, err
	}

	var proof Proof
	if err := json.Unmarshal(data, &proof); err != nil {
		return nil, err
	}

	return &proof, nil
}

// FindDivergentStep finds the first step where local execution diverges from claimed state.
func (e *CannonExecutor) FindDivergentStep(
	ctx context.Context,
	inputState string,
	claimedStateHash common.Hash,
	maxSteps uint64,
) (uint64, *Proof, error) {
	// Binary search for the divergent step
	low := uint64(0)
	high := maxSteps

	e.logger.Printf("Finding divergent step: claimed=%s maxSteps=%d", claimedStateHash.Hex()[:10], maxSteps)

	for low < high {
		select {
		case <-ctx.Done():
			return 0, nil, ctx.Err()
		default:
		}

		mid := (low + high) / 2

		// Run to mid step
		result, err := e.RunToStep(ctx, inputState, mid)
		if err != nil {
			return 0, nil, fmt.Errorf("failed to run to step %d: %w", mid, err)
		}

		// Get state hash at mid
		stateHash, err := e.GetStateHash(ctx, result.FinalState)
		if err != nil {
			return 0, nil, fmt.Errorf("failed to get state hash at step %d: %w", mid, err)
		}

		e.logger.Printf("Step %d: hash=%s", mid, stateHash.Hex()[:10])

		if stateHash == claimedStateHash {
			// States match, divergence is after mid
			low = mid + 1
		} else {
			// States don't match, divergence is at or before mid
			high = mid
		}
	}

	// Generate proof at the divergent step
	proof, err := e.GenerateProofAt(ctx, inputState, low)
	if err != nil {
		return low, nil, fmt.Errorf("failed to generate proof at step %d: %w", low, err)
	}

	e.logger.Printf("Found divergent step: %d", low)

	return low, proof, nil
}
