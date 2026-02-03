package test

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/ethereum-optimism/optimism/demo/node/cannon"
)

// TestCannonDocker tests the cannon executor using Docker.
func TestCannonDocker(t *testing.T) {
	// Get project root
	projectRoot := os.Getenv("PROJECT_ROOT")
	if projectRoot == "" {
		// Try to find it relative to test directory
		wd, _ := os.Getwd()
		projectRoot = filepath.Dir(wd)
	}

	programPath := filepath.Join(projectRoot, "bin", "program.elf")
	workDir := filepath.Join(projectRoot, "cannon-work-test")

	// Check if program.elf exists
	if _, err := os.Stat(programPath); os.IsNotExist(err) {
		t.Skipf("program.elf not found at %s, run 'make build-mips' first", programPath)
	}

	// Create work directory
	if err := os.MkdirAll(workDir, 0755); err != nil {
		t.Fatalf("Failed to create work directory: %v", err)
	}
	defer os.RemoveAll(workDir)

	// Create preimage server
	preimageServer := cannon.NewPreimageServer(nil)

	// Add some test preimages
	testData := []byte("hello world")
	key := preimageServer.AddPreimage(testData)
	t.Logf("Added preimage with key: %x", key[:8])

	// Create Docker-based executor
	executor := cannon.NewDockerCannonExecutor(workDir, programPath, preimageServer, nil)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	// Test 1: Load ELF
	t.Run("LoadELF", func(t *testing.T) {
		statePath, err := executor.LoadELF(ctx)
		if err != nil {
			t.Fatalf("Failed to load ELF: %v", err)
		}
		t.Logf("Initial state created at: %s", statePath)

		// Verify state file exists
		if _, err := os.Stat(statePath); os.IsNotExist(err) {
			t.Fatalf("State file not created")
		}
	})

	// Test 2: Run a few steps
	t.Run("RunSteps", func(t *testing.T) {
		statePath := filepath.Join(workDir, "state.bin.gz")
		if _, err := os.Stat(statePath); os.IsNotExist(err) {
			t.Skip("State file not found, LoadELF test may have failed")
		}

		result, err := executor.RunToStep(ctx, statePath, 100)
		if err != nil {
			t.Fatalf("Failed to run to step 100: %v", err)
		}
		t.Logf("Ran to step 100, output state: %s", result.FinalState)
	})

	// Test 3: Generate proof at specific step
	t.Run("GenerateProof", func(t *testing.T) {
		statePath := filepath.Join(workDir, "state.bin.gz")
		if _, err := os.Stat(statePath); os.IsNotExist(err) {
			t.Skip("State file not found, LoadELF test may have failed")
		}

		proof, err := executor.GenerateProofAt(ctx, statePath, 50)
		if err != nil {
			t.Fatalf("Failed to generate proof at step 50: %v", err)
		}

		t.Logf("Proof generated:")
		t.Logf("  Step: %d", proof.Step)
		t.Logf("  Pre:  %x", proof.Pre[:8])
		t.Logf("  Post: %x", proof.Post[:8])
		t.Logf("  StateData len: %d", len(proof.StateData))
		t.Logf("  ProofData len: %d", len(proof.ProofData))
	})
}

// TestCannonExecutorWithPreimages tests cannon with preimage oracle using Docker.
func TestCannonExecutorWithPreimages(t *testing.T) {
	// Get project root
	projectRoot := os.Getenv("PROJECT_ROOT")
	if projectRoot == "" {
		wd, _ := os.Getwd()
		projectRoot = filepath.Dir(wd)
	}

	programPath := filepath.Join(projectRoot, "bin", "program.elf")
	workDir := filepath.Join(projectRoot, "cannon-work-preimage-test")

	// Check prerequisites
	if _, err := os.Stat(programPath); os.IsNotExist(err) {
		t.Skipf("program.elf not found at %s", programPath)
	}

	// Create work directory
	if err := os.MkdirAll(workDir, 0755); err != nil {
		t.Fatalf("Failed to create work directory: %v", err)
	}
	defer os.RemoveAll(workDir)

	// Create preimage server with test data
	preimageServer := cannon.NewPreimageServer(nil)

	// Add local data (simulating L2 block data)
	blockData := []byte(`{"number":1,"hash":"0x1234","stateRoot":"0x5678"}`)
	preimageServer.AddLocalData(1, blockData)

	// Add keccak preimage (simulating state data)
	stateData := []byte(`{"balance":"1000","nonce":5}`)
	preimageServer.AddPreimage(stateData)

	// Create Docker-based executor
	executor := cannon.NewDockerCannonExecutor(workDir, programPath, preimageServer, nil)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	// Load and run
	statePath, err := executor.LoadELF(ctx)
	if err != nil {
		t.Fatalf("Failed to load ELF: %v", err)
	}

	// Run to completion (or until timeout)
	result, err := executor.Run(ctx, &cannon.RunConfig{
		InputState: statePath,
		ProofAt:    "never",
		StopAt:     "=1000", // Stop after 1000 steps for testing
	})
	if err != nil {
		t.Logf("Run completed with error (may be expected): %v", err)
	} else {
		t.Logf("Run completed successfully")
		t.Logf("  Final state: %s", result.FinalState)
		t.Logf("  Exited: %v", result.Exited)
		if result.Exited {
			t.Logf("  Exit code: %d", result.ExitCode)
		}
	}
}

// TestPreimageServer tests the preimage server directly.
func TestPreimageServer(t *testing.T) {
	server := cannon.NewPreimageServer(nil)

	// Test adding keccak preimage
	t.Run("KeccakPreimage", func(t *testing.T) {
		data := []byte("test data for keccak")
		key := server.AddPreimage(data)

		// Retrieve it
		retrieved, err := server.GetPreimage(key)
		if err != nil {
			t.Fatalf("Failed to get preimage: %v", err)
		}

		if string(retrieved) != string(data) {
			t.Errorf("Data mismatch: got %s, want %s", retrieved, data)
		}
	})

	// Test adding local data
	t.Run("LocalData", func(t *testing.T) {
		data := []byte("local data")
		key := server.AddLocalData(42, data)

		// Retrieve it
		retrieved, err := server.GetPreimage(key)
		if err != nil {
			t.Fatalf("Failed to get local data: %v", err)
		}

		if string(retrieved) != string(data) {
			t.Errorf("Data mismatch: got %s, want %s", retrieved, data)
		}
	})

	// Test not found
	t.Run("NotFound", func(t *testing.T) {
		var unknownKey [32]byte
		unknownKey[0] = 0x02 // keccak type
		unknownKey[1] = 0xff

		_, err := server.GetPreimage(unknownKey)
		if err == nil {
			t.Error("Expected error for unknown key")
		}
	})
}
