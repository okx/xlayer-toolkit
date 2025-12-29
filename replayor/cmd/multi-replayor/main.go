package main

import (
	"context"
	_ "embed"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	oplog "github.com/ethereum-optimism/optimism/op-service/log"
	"github.com/ethereum/go-ethereum/log"
	"github.com/urfave/cli/v2"
)

var (
	Version   = "v0.0.1"
	GitCommit = ""
	GitDate   = ""
)

//go:embed embed/docker-compose.yml
var dockerComposeTemplate string

//go:embed embed/replayor.docker.env.example
var replayorDockerEnvTemplate string

//go:embed embed/reth.docker.env.example
var rethDockerEnvTemplate string

//go:embed embed/unwind.sh
var unwindShTemplate string

//go:embed embed/reth.sh
var rethShTemplate string

//go:embed embed/replayor.sh
var replayorShTemplate string

//go:embed embed/Dockerfile
var dockerfileTemplate string

func main() {
	oplog.SetupDefaults()
	app := cli.NewApp()
	app.Version = fmt.Sprintf("%s-%s-%s", Version, GitCommit, GitDate)
	app.Name = "multi-replayor"
	app.Description = "Utility to schedule and run multiple replayor instances in parallel using docker-compose"
	app.Flags = []cli.Flag{
		&cli.StringFlag{
			Name:     "source-node-url",
			Usage:    "The URL of the source node to fetch transactions from",
			Required: true,
			EnvVars:  []string{"SOURCE_NODE_URL"},
		},
		&cli.StringFlag{
			Name:     "source-node-data",
			Usage:    "The source data directory to copy for each partition",
			Required: true,
			EnvVars:  []string{"SOURCE_NODE_DATA"},
		},
		&cli.IntFlag{
			Name:     "from",
			Usage:    "Starting block number",
			Required: true,
			EnvVars:  []string{"FROM_BLOCK"},
		},
		&cli.IntFlag{
			Name:     "to",
			Usage:    "Ending block number (inclusive)",
			Required: true,
			EnvVars:  []string{"TO_BLOCK"},
		},
		&cli.IntFlag{
			Name:     "partition",
			Usage:    "Number of partitions to split the block range into",
			Required: true,
			EnvVars:  []string{"PARTITION"},
		},
		&cli.StringFlag{
			Name:    "work-dir",
			Usage:   "Working directory to create partition directories",
			Value:   "./multi-replayor-work",
			EnvVars: []string{"WORK_DIR"},
		},
		&cli.StringFlag{
			Name:    "rollup-config-path",
			Usage:   "Path to rollup.json file",
			Value:   "./rollup.json",
			EnvVars: []string{"ROLLUP_CONFIG_PATH"},
		},
		&cli.StringFlag{
			Name:    "jwt-secret-path",
			Usage:   "Path to jwt.txt file",
			Value:   "./jwt.txt",
			EnvVars: []string{"JWT_SECRET_PATH"},
		},
		&cli.StringFlag{
			Name:    "genesis-json-path",
			Usage:   "Path to genesis.json file (optional)",
			Value:   "./genesis.json",
			EnvVars: []string{"GENESIS_JSON_PATH"},
		},
		&cli.StringFlag{
			Name:    "chain",
			Usage:   "empty or xlayer-testnet or xlayer-mainnet",
			Value:   "",
			EnvVars: []string{"GENESIS_JSON_PATH"},
		},
	}
	app.Flags = append(app.Flags, oplog.CLIFlags("MULTI_REPLAYOR")...)

	app.Action = func(cliCtx *cli.Context) error {
		logger := oplog.NewLogger(oplog.AppOut(cliCtx), oplog.ReadCLIConfig(cliCtx))

		sourceNodeUrl := cliCtx.String("source-node-url")
		sourceNodeData := cliCtx.String("source-node-data")
		from := cliCtx.Int("from")
		to := cliCtx.Int("to")
		partition := cliCtx.Int("partition")
		workDir := cliCtx.String("work-dir")
		rollupConfigPath := cliCtx.String("rollup-config-path")
		jwtSecretPath := cliCtx.String("jwt-secret-path")
		genesisJsonPath := cliCtx.String("genesis-json-path")
		chain := cliCtx.String("chain")

		// Validate inputs
		if from < 0 {
			return fmt.Errorf("from block must be non-negative, got %d", from)
		}
		if to < from {
			return fmt.Errorf("to block (%d) must be >= from block (%d)", to, from)
		}
		if partition <= 0 {
			return fmt.Errorf("partition must be positive, got %d", partition)
		}

		// Validate source data directory
		if _, err := os.Stat(sourceNodeData); os.IsNotExist(err) {
			return fmt.Errorf("source-node-data directory does not exist: %s", sourceNodeData)
		}

		logger.Info("Starting multi-replayor",
			"source-node-url", sourceNodeUrl,
			"source-node-data", sourceNodeData,
			"from", from,
			"to", to,
			"partition", partition,
			"work-dir", workDir)

		// Calculate block ranges for each partition
		totalBlocks := to - from
		blocksPerPartition := totalBlocks / partition
		remainder := totalBlocks % partition

		logger.Info("Calculated partition ranges",
			"total-blocks", totalBlocks,
			"blocks-per-partition", blocksPerPartition,
			"remainder", remainder)

		// Create work directory
		if err := os.MkdirAll(workDir, 0755); err != nil {
			return fmt.Errorf("failed to create work directory: %w", err)
		}

		// Create context for graceful shutdown
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()

		// Setup signal handling
		sigChan := make(chan os.Signal, 1)
		signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)
		go func() {
			<-sigChan
			logger.Info("Received shutdown signal, stopping all docker-compose instances")
			cancel()
		}()

		// Start all partitions
		var wg sync.WaitGroup
		var mu sync.Mutex
		var errors []error

		for i := 0; i < partition; i++ {
			// Calculate start block: base + blocks from previous partitions + extra blocks from remainder
			partitionStart := from + i*blocksPerPartition
			if i > 0 {
				// Add extra blocks from remainder that were distributed to previous partitions
				partitionStart += min(i, remainder)
			}

			partitionBlocks := blocksPerPartition
			// Distribute remainder blocks to first few partitions
			if i < remainder {
				partitionBlocks++
			}
			partitionEnd := partitionStart + partitionBlocks

			// Adjust partitionEnd if it exceeds 'to'
			if partitionEnd > to {
				partitionEnd = to
				partitionBlocks = partitionEnd - partitionStart
			}

			wg.Add(1)
			go func(partitionID int, startBlock, endBlock, blockCount int) {
				defer wg.Done()

				logger.Info("Starting partition",
					"partition", partitionID,
					"start-block", startBlock,
					"end-block", endBlock,
					"block-count", blockCount)

				err := runPartition(ctx, logger, workDir, partitionID, sourceNodeUrl, sourceNodeData, startBlock, blockCount, rollupConfigPath, jwtSecretPath, genesisJsonPath, chain)
				if err != nil {
					mu.Lock()
					errors = append(errors, fmt.Errorf("partition %d failed: %w", partitionID, err))
					mu.Unlock()
					logger.Error("Partition failed",
						"partition", partitionID,
						"error", err)
				} else {
					logger.Info("Partition completed",
						"partition", partitionID)
				}
			}(i, partitionStart, partitionEnd, partitionBlocks)
		}

		// Wait for all partitions to complete
		wg.Wait()

		if len(errors) > 0 {
			logger.Error("Some partitions failed", "error-count", len(errors))
			for _, err := range errors {
				logger.Error("Error", "error", err)
			}
			return fmt.Errorf("%d partition(s) failed", len(errors))
		}

		logger.Info("All partitions completed successfully")
		return nil
	}

	err := app.Run(os.Args)
	if err != nil {
		log.Crit("Application failed", "message", err)
		os.Exit(1)
	}
}

func runPartition(ctx context.Context, logger log.Logger, workDir string, partitionID int, sourceNodeUrl, sourceNodeData string, startBlock, blockCount int, rollupConfigPath, jwtSecretPath, genesisJsonPath string, chain string) error {
	partitionDir := filepath.Join(workDir, fmt.Sprintf("multi-replayor-%d", partitionID))

	// Create partition directory
	if err := os.MkdirAll(partitionDir, 0755); err != nil {
		return fmt.Errorf("failed to create partition directory: %w", err)
	}

	// Calculate ports
	authrpcPort := 16700 + partitionID
	wsPort := 16800 + partitionID
	httpPort := 16900 + partitionID

	logger.Info("Setting up partition",
		"partition", partitionID,
		"directory", partitionDir,
		"authrpc-port", authrpcPort,
		"ws-port", wsPort,
		"http-port", httpPort)

	// Copy source data directory
	destDataDir := filepath.Join(partitionDir, "reth-data")
	if err := copyDirectory(sourceNodeData, destDataDir); err != nil {
		return fmt.Errorf("failed to copy source data: %w", err)
	}

	// Copy required configuration files and track which ones exist
	rollupExists := fileExists(rollupConfigPath)
	if rollupExists {
		if err := copyFileIfExists(rollupConfigPath, filepath.Join(partitionDir, "rollup.json")); err != nil {
			return fmt.Errorf("failed to copy rollup.json: %w", err)
		}
	}

	jwtExists := fileExists(jwtSecretPath)
	if jwtExists {
		if err := copyFileIfExists(jwtSecretPath, filepath.Join(partitionDir, "jwt.txt")); err != nil {
			return fmt.Errorf("failed to copy jwt.txt: %w", err)
		}
	}

	genesisExists := fileExists(genesisJsonPath)
	if genesisExists {
		if err := copyFileIfExists(genesisJsonPath, filepath.Join(partitionDir, "genesis.json")); err != nil {
			logger.Warn("failed to copy genesis.json", "error", err)
			genesisExists = false
		}
	}

	if !rollupExists {
		return fmt.Errorf("rollup.json not found at %s", rollupConfigPath)
	}
	if !jwtExists {
		return fmt.Errorf("jwt.txt not found at %s", jwtSecretPath)
	}
	if !genesisExists {
		logger.Warn("genesis.json not found, continuing without it", "path", genesisJsonPath)
	}

	// Generate configuration files
	if err := generateConfigFiles(partitionDir, partitionID, sourceNodeUrl, startBlock, blockCount, authrpcPort, wsPort, httpPort, genesisExists, chain); err != nil {
		return fmt.Errorf("failed to generate config files: %w", err)
	}

	// Setup log files
	unwindLog, err := os.Create(filepath.Join(partitionDir, "unwind.log"))
	if err != nil {
		return fmt.Errorf("failed to create unwind.log: %w", err)
	}
	defer unwindLog.Close()

	nodeLog, err := os.Create(filepath.Join(partitionDir, "node.log"))
	if err != nil {
		return fmt.Errorf("failed to create node.log: %w", err)
	}
	defer nodeLog.Close()

	replayorLog, err := os.Create(filepath.Join(partitionDir, "replayor.log"))
	if err != nil {
		return fmt.Errorf("failed to create replayor.log: %w", err)
	}
	defer replayorLog.Close()

	// Step 1: Run node-unwind
	logger.Info("Running node-unwind", "partition", partitionID)
	wd, _ := os.Getwd()
	logger.Info("Running replayor with docker compose file", "partition", partitionID, "directory", filepath.Join(partitionDir, "docker-compose.yml"), "wd", wd)
	unwindCmd := exec.CommandContext(ctx, "docker", "compose", "-f", "docker-compose.yml", "up", "node-unwind")
	unwindCmd.Dir = partitionDir
	unwindCmd.Stdout = io.MultiWriter(unwindLog, os.Stdout)
	unwindCmd.Stderr = io.MultiWriter(unwindLog, os.Stderr)
	// Run the command - even if it returns success, we need to check container exit code
	unwindCmdErr := unwindCmd.Run()

	// Always check container exit code, even if docker compose command succeeded
	unwindExitCode, unwindCheckErr := checkContainerExitCode(ctx, partitionDir, "node-unwind", partitionID, logger)
	if unwindCheckErr == nil {
		if unwindExitCode != 0 {
			logger.Error("node-unwind container exited with non-zero code", "partition", partitionID, "exit-code", unwindExitCode)
			return fmt.Errorf("partition %d: node-unwind container exited with status %d", partitionID, unwindExitCode)
		}
		logger.Info("node-unwind container exited successfully", "partition", partitionID, "exit-code", unwindExitCode)
	} else {
		logger.Warn("Failed to check container exit code", "partition", partitionID, "error", unwindCheckErr)
	}

	// Also check if docker compose command itself failed
	if unwindCmdErr != nil {
		if err := checkCommandExitStatus(unwindCmdErr, fmt.Sprintf("partition-%d node-unwind", partitionID)); err != nil {
			logger.Error("node-unwind command failed", "partition", partitionID, "error", err)
			return fmt.Errorf("partition %d: node-unwind failed: %w", partitionID, err)
		}
	}

	// Step 2: Run node (in background)
	logger.Info("Starting node", "partition", partitionID)
	nodeCmd := exec.CommandContext(ctx, "docker", "compose", "-f", "docker-compose.yml", "up", "-d", "node")
	nodeCmd.Dir = partitionDir
	nodeCmd.Stdout = io.MultiWriter(nodeLog, os.Stdout)
	nodeCmd.Stderr = io.MultiWriter(nodeLog, os.Stderr)
	if err := checkCommandExitStatus(nodeCmd.Run(), fmt.Sprintf("partition-%d node start", partitionID)); err != nil {
		logger.Error("node start command failed", "partition", partitionID, "error", err)
		return fmt.Errorf("partition %d: node start failed: %w", partitionID, err)
	}

	// Stream node logs in background
	go func() {
		logsCmd := exec.CommandContext(ctx, "docker", "compose", "-f", "docker-compose.yml", "logs", "-f", "node")
		logsCmd.Dir = partitionDir
		logsCmd.Stdout = io.MultiWriter(nodeLog, os.Stdout)
		logsCmd.Stderr = io.MultiWriter(nodeLog, os.Stderr)
		logsCmd.Run()
	}()

	// Wait for node to be ready by checking HTTP endpoint
	logger.Info("Waiting for node to be ready", "partition", partitionID, "http-port", httpPort)
	if err := waitForNodeReady(ctx, logger, httpPort, 60); err != nil {
		logger.Error("node did not become ready", "partition", partitionID, "error", err)
		return fmt.Errorf("partition %d: node did not become ready: %w", partitionID, err)
	}
	logger.Info("Node is ready", "partition", partitionID)

	// Step 3: Run replayor
	logger.Info("Running replayor", "partition", partitionID)
	replayorCmd := exec.CommandContext(ctx, "docker", "compose", "-f", "docker-compose.yml", "up", "replayor")
	replayorCmd.Dir = partitionDir
	replayorCmd.Stdout = io.MultiWriter(replayorLog, os.Stdout)
	replayorCmd.Stderr = io.MultiWriter(replayorLog, os.Stderr)
	// Run the command - even if it returns success, we need to check container exit code
	replayorCmdErr := replayorCmd.Run()

	// Always check container exit code, even if docker compose command succeeded
	replayorExitCode, replayorCheckErr := checkContainerExitCode(ctx, partitionDir, "replayor", partitionID, logger)
	if replayorCheckErr == nil {
		if replayorExitCode != 0 {
			logger.Error("replayor container exited with non-zero code", "partition", partitionID, "exit-code", replayorExitCode)
			return fmt.Errorf("partition %d: replayor container exited with status %d", partitionID, replayorExitCode)
		}
		logger.Info("replayor container exited successfully", "partition", partitionID, "exit-code", replayorExitCode)
	} else {
		logger.Warn("Failed to check container exit code", "partition", partitionID, "error", replayorCheckErr)
	}

	// Also check if docker compose command itself failed
	if replayorCmdErr != nil {
		if err := checkCommandExitStatus(replayorCmdErr, fmt.Sprintf("partition-%d replayor", partitionID)); err != nil {
			logger.Error("replayor command failed", "partition", partitionID, "error", err)
			return fmt.Errorf("partition %d: replayor failed: %w", partitionID, err)
		}
	}

	// Stop node after replayor completes
	logger.Info("Stopping node", "partition", partitionID)
	stopCmd := exec.CommandContext(ctx, "docker", "compose", "-f", "docker-compose.yml", "down")
	stopCmd.Dir = partitionDir
	stopCmd.Run() // Ignore errors on cleanup

	return nil
}

func generateConfigFiles(partitionDir string, partitionID int, sourceNodeUrl string, startBlock, blockCount, authrpcPort, wsPort, httpPort int, genesisExists bool, chain string) error {
	// Generate docker-compose.yml
	dockerComposePath := filepath.Join(partitionDir, "docker-compose.yml")
	dockerComposeContent := dockerComposeTemplate

	// Replace ports in all services (node-unwind, node-init, node)
	// Format: "9123:9123" -> "httpPort:httpPort" and "8553:8553" -> "authrpcPort:authrpcPort"
	dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "9123:9123", fmt.Sprintf("%d:%d", httpPort, httpPort))
	dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "8553:8553", fmt.Sprintf("%d:%d", authrpcPort, authrpcPort))

	// Replace network name
	dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "${DOCKER_NETWORK:-dev-replayor}", fmt.Sprintf("dev-replayor-%d", partitionID))

	// Remove genesis.json volume mount if file doesn't exist
	if !genesisExists {
		// Remove the genesis.json volume line from all services
		dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "      - ${GENESIS_JSON_PATH:-./genesis.json}:/app/genesis.json:ro\n", "")
		// Also handle cases where it might be on the same line or different format
		dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "- ${GENESIS_JSON_PATH:-./genesis.json}:/app/genesis.json:ro", "")
		// Set environment variable to empty to avoid Docker trying to resolve it
		dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "${GENESIS_JSON_PATH:-./genesis.json}", "")
	} else {
		// Ensure the path is relative to partition directory
		dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "${GENESIS_JSON_PATH:-./genesis.json}", "./genesis.json")
	}

	// Ensure other paths are also relative
	dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "${ROLLUP_JSON_PATH:-./rollup.json}", "./rollup.json")
	dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "${JWT_TXT_PATH:-./jwt.txt}", "./jwt.txt")
	dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "${RETH_DATA_PATH:-./reth-data}", "./reth-data")

	if err := os.WriteFile(dockerComposePath, []byte(dockerComposeContent), 0644); err != nil {
		return fmt.Errorf("failed to write docker-compose.yml: %w", err)
	}

	// Generate reth.docker.env
	rethEnvPath := filepath.Join(partitionDir, "reth.docker.env")
	rethEnvContent := strings.ReplaceAll(rethDockerEnvTemplate, "RETH_HTTP_PORT=9123", fmt.Sprintf("RETH_HTTP_PORT=%d", httpPort))
	rethEnvContent = strings.ReplaceAll(rethEnvContent, "RETH_WS_PORT=9124", fmt.Sprintf("RETH_WS_PORT=%d", wsPort))
	rethEnvContent = strings.ReplaceAll(rethEnvContent, "RETH_AUTHRPC_PORT=8553", fmt.Sprintf("RETH_AUTHRPC_PORT=%d", authrpcPort))
	rethEnvContent = strings.ReplaceAll(rethEnvContent, "RETH_DATA_DIR=./reth-data", "RETH_DATA_DIR=./reth-data")
	if chain == "xlayer-testnet" || chain == "xlayer-mainnet" {
		rethEnvContent = strings.ReplaceAll(rethEnvContent, "RETH_CHAIN=./genesis.json", fmt.Sprintf("RETH_CHAIN=%s", chain))
	}
	// Set unwind target block to startBlock - 1 (unwind to one block before the start)
	unwindBlock := startBlock
	if unwindBlock < 0 {
		unwindBlock = 0
	}
	rethEnvContent = strings.ReplaceAll(rethEnvContent, "UNWIND_TO_BLOCK=8602500", fmt.Sprintf("UNWIND_TO_BLOCK=%d", unwindBlock))
	if err := os.WriteFile(rethEnvPath, []byte(rethEnvContent), 0644); err != nil {
		return fmt.Errorf("failed to write reth.docker.env: %w", err)
	}

	// Generate replayor.docker.env
	replayorEnvPath := filepath.Join(partitionDir, "replayor.docker.env")
	replayorEnvContent := strings.ReplaceAll(replayorDockerEnvTemplate, "SOURCE_NODE_URL=http://host.docker.internal:8123", fmt.Sprintf("SOURCE_NODE_URL=%s", sourceNodeUrl))
	replayorEnvContent = strings.ReplaceAll(replayorEnvContent, "ENGINE_API_URL=http://node:8553", fmt.Sprintf("ENGINE_API_URL=http://node:%d", authrpcPort))
	replayorEnvContent = strings.ReplaceAll(replayorEnvContent, "EXECUTION_URL=http://node:9123", fmt.Sprintf("EXECUTION_URL=http://node:%d", httpPort))
	replayorEnvContent = strings.ReplaceAll(replayorEnvContent, "CONTINUOUS_MODE=true", "CONTINUOUS_MODE=false")
	replayorEnvContent = strings.ReplaceAll(replayorEnvContent, "BLOCK_COUNT=1", fmt.Sprintf("BLOCK_COUNT=%d", blockCount))
	// Add benchmark start block
	replayorEnvContent += fmt.Sprintf("\nBENCHMARK_START_BLOCK=%d\n", startBlock)
	if err := os.WriteFile(replayorEnvPath, []byte(replayorEnvContent), 0644); err != nil {
		return fmt.Errorf("failed to write replayor.docker.env: %w", err)
	}

	// Copy shell scripts
	scripts := map[string]string{
		"unwind.sh":   unwindShTemplate,
		"reth.sh":     rethShTemplate,
		"replayor.sh": replayorShTemplate,
	}

	for name, content := range scripts {
		scriptPath := filepath.Join(partitionDir, name)
		if err := os.WriteFile(scriptPath, []byte(content), 0755); err != nil {
			return fmt.Errorf("failed to write %s: %w", name, err)
		}
	}

	// Copy Dockerfile
	dockerfilePath := filepath.Join(partitionDir, "Dockerfile")
	if err := os.WriteFile(dockerfilePath, []byte(dockerfileTemplate), 0644); err != nil {
		return fmt.Errorf("failed to write Dockerfile: %w", err)
	}

	return nil
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func copyFileIfExists(src, dst string) error {
	if !fileExists(src) {
		return nil // File doesn't exist, skip
	}

	// Ensure destination directory exists
	if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
		return fmt.Errorf("failed to create destination directory: %w", err)
	}

	srcFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer srcFile.Close()

	dstFile, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		return err
	}
	defer dstFile.Close()

	_, err = io.Copy(dstFile, srcFile)
	return err
}

func waitForNodeReady(ctx context.Context, logger log.Logger, httpPort int, maxWaitSeconds int) error {
	url := fmt.Sprintf("http://127.0.0.1:%d", httpPort)
	client := &http.Client{
		Timeout: 2 * time.Second,
	}

	deadline := time.Now().Add(time.Duration(maxWaitSeconds) * time.Second)
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			// Try to call eth_blockNumber to check if node is ready
			req, err := http.NewRequestWithContext(ctx, "POST", url, strings.NewReader(`{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}`))
			if err != nil {
				continue
			}
			req.Header.Set("Content-Type", "application/json")

			resp, err := client.Do(req)
			if err != nil {
				logger.Debug("Node not ready yet", "port", httpPort, "error", err)
				continue
			}
			resp.Body.Close()

			if resp.StatusCode == http.StatusOK {
				logger.Info("Node is ready", "port", httpPort)
				return nil
			}
		}
	}

	return fmt.Errorf("node did not become ready within %d seconds", maxWaitSeconds)
}

func copyDirectory(src, dst string) error {
	return filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		relPath, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}

		dstPath := filepath.Join(dst, relPath)

		if info.IsDir() {
			return os.MkdirAll(dstPath, info.Mode())
		}

		// Copy file
		srcFile, err := os.Open(path)
		if err != nil {
			return err
		}
		defer srcFile.Close()

		dstFile, err := os.OpenFile(dstPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, info.Mode())
		if err != nil {
			return err
		}
		defer dstFile.Close()

		_, err = io.Copy(dstFile, srcFile)
		return err
	})
}

// checkCommandExitStatus checks if a command exited with a non-zero status code
// and returns an error with the exit code if so
func checkCommandExitStatus(err error, cmdName string) error {
	if err == nil {
		return nil
	}

	// Check if it's an ExitError to get the exit code
	if exitErr, ok := err.(*exec.ExitError); ok {
		if status, ok := exitErr.Sys().(syscall.WaitStatus); ok {
			exitCode := status.ExitStatus()
			// Include stderr output if available
			stderr := string(exitErr.Stderr)
			if stderr != "" {
				return fmt.Errorf("%s exited with status %d\nstderr: %s", cmdName, exitCode, stderr)
			}
			return fmt.Errorf("%s exited with status %d", cmdName, exitCode)
		}
		// If we can't get the exit code, still return the error
		return fmt.Errorf("%s failed: %w", cmdName, err)
	}

	// For other types of errors (e.g., context cancellation), return as-is
	return err
}

// checkContainerExitCode checks the exit code of a docker compose service container
// Returns the exit code and nil error if successful, or 0 and error if check failed
func checkContainerExitCode(ctx context.Context, partitionDir, serviceName string, partitionID int, logger log.Logger) (int, error) {
	// Get the project name from the directory name
	projectName := filepath.Base(partitionDir)

	// First, try to get container ID using docker compose ps
	psCmd := exec.CommandContext(ctx, "docker", "compose", "-f", "docker-compose.yml", "-p", projectName, "ps", "-a", "-q", serviceName)
	psCmd.Dir = partitionDir
	containerIDBytes, err := psCmd.Output()
	if err != nil {
		logger.Debug("Failed to get container ID with docker compose", "partition", partitionID, "service", serviceName, "error", err)
		return 0, fmt.Errorf("failed to get container ID: %w", err)
	}

	containerID := strings.TrimSpace(string(containerIDBytes))
	if containerID == "" {
		return 0, fmt.Errorf("container not found for service %s", serviceName)
	}

	// Use docker inspect to get the exit code
	inspectCmd := exec.CommandContext(ctx, "docker", "inspect", "--format", "{{.State.ExitCode}}", containerID)
	exitCodeBytes, err := inspectCmd.Output()
	if err != nil {
		return 0, fmt.Errorf("failed to inspect container: %w", err)
	}

	var exitCode int
	if _, err := fmt.Sscanf(strings.TrimSpace(string(exitCodeBytes)), "%d", &exitCode); err != nil {
		return 0, fmt.Errorf("failed to parse exit code: %w", err)
	}

	return exitCode, nil
}

// min returns the minimum of two integers
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
