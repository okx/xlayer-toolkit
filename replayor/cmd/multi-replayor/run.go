package main

import (
	"context"
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

// RunCommand returns the run subcommand
func RunCommand() *cli.Command {
	flags := []cli.Flag{
		&cli.StringFlag{
			Name:     "source-node-url",
			Usage:    "The URL of the source node to fetch transactions from",
			Required: true,
			EnvVars:  []string{"SOURCE_NODE_URL"},
		},
		&cli.StringFlag{
			Name:    "template-dir",
			Usage:   "Directory containing reth-{block} template directories (defaults to work-dir)",
			EnvVars: []string{"TEMPLATE_DIR"},
		},
	}
	flags = append(flags, SharedFlags()...)
	flags = append(flags, oplog.CLIFlags("MULTI_REPLAYOR")...)

	return &cli.Command{
		Name:  "run",
		Usage: "Run multiple replayor instances in parallel",
		Flags: flags,
		Action: func(cliCtx *cli.Context) error {
			return runAction(cliCtx)
		},
	}
}

func runAction(cliCtx *cli.Context) error {
	logger := oplog.NewLogger(oplog.AppOut(cliCtx), oplog.ReadCLIConfig(cliCtx))

	sourceNodeUrl := cliCtx.String("source-node-url")
	sourceNodeData := cliCtx.String("source-node-data")
	from := cliCtx.Int("from")
	to := cliCtx.Int("to")
	partition := cliCtx.Int("partition")
	workDir := cliCtx.String("work-dir")
	templateDir := cliCtx.String("template-dir")
	rollupConfigPath := cliCtx.String("rollup-config-path")
	jwtSecretPath := cliCtx.String("jwt-secret-path")
	genesisJsonPath := cliCtx.String("genesis-json-path")
	chain := cliCtx.String("chain")

	// Use work-dir as template-dir if not specified
	if templateDir == "" {
		templateDir = workDir
	}

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

	// Check if we have templates or source-node-data
	templates, _ := FindTemplateDirectories(templateDir)
	hasTemplates := len(templates) > 0

	if !hasTemplates && sourceNodeData == "" {
		return fmt.Errorf("either --source-node-data or templates in --template-dir must be provided")
	}

	if sourceNodeData != "" {
		if _, err := os.Stat(sourceNodeData); os.IsNotExist(err) {
			return fmt.Errorf("source-node-data directory does not exist: %s", sourceNodeData)
		}
	}

	logger.Info("Starting multi-replayor",
		"source-node-url", sourceNodeUrl,
		"source-node-data", sourceNodeData,
		"template-dir", templateDir,
		"has-templates", hasTemplates,
		"from", from,
		"to", to,
		"partition", partition,
		"work-dir", workDir)

	// Calculate block ranges for each partition
	ranges := CalculatePartitionRanges(from, to, partition)

	logger.Info("Calculated partition ranges",
		"total-blocks", to-from,
		"partition-count", len(ranges))

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

	for _, r := range ranges {
		wg.Add(1)
		go func(pr PartitionRange) {
			defer wg.Done()

			logger.Info("Starting partition",
				"partition", pr.ID,
				"start-block", pr.StartBlock,
				"end-block", pr.EndBlock,
				"block-count", pr.BlockCount)

			err := runPartition(ctx, logger, runPartitionConfig{
				workDir:          workDir,
				templateDir:      templateDir,
				partitionID:      pr.ID,
				sourceNodeUrl:    sourceNodeUrl,
				sourceNodeData:   sourceNodeData,
				startBlock:       pr.StartBlock,
				blockCount:       pr.BlockCount,
				rollupConfigPath: rollupConfigPath,
				jwtSecretPath:    jwtSecretPath,
				genesisJsonPath:  genesisJsonPath,
				chain:            chain,
			})
			if err != nil {
				mu.Lock()
				errors = append(errors, fmt.Errorf("partition %d failed: %w", pr.ID, err))
				mu.Unlock()
				logger.Error("Partition failed",
					"partition", pr.ID,
					"error", err)
			} else {
				logger.Info("Partition completed",
					"partition", pr.ID)
			}
		}(r)
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

type runPartitionConfig struct {
	workDir          string
	templateDir      string
	partitionID      int
	sourceNodeUrl    string
	sourceNodeData   string
	startBlock       int
	blockCount       int
	rollupConfigPath string
	jwtSecretPath    string
	genesisJsonPath  string
	chain            string
}

func runPartition(ctx context.Context, logger log.Logger, cfg runPartitionConfig) error {
	partitionDir := filepath.Join(cfg.workDir, fmt.Sprintf("multi-replayor-%d", cfg.partitionID))

	// Create partition directory
	if err := os.MkdirAll(partitionDir, 0755); err != nil {
		return fmt.Errorf("failed to create partition directory: %w", err)
	}

	// Calculate ports
	authrpcPort := 16700 + cfg.partitionID
	wsPort := 16800 + cfg.partitionID
	httpPort := 16900 + cfg.partitionID

	logger.Info("Setting up partition",
		"partition", cfg.partitionID,
		"directory", partitionDir,
		"authrpc-port", authrpcPort,
		"ws-port", wsPort,
		"http-port", httpPort)

	// Determine data source: template or source-node-data
	destDataDir := filepath.Join(partitionDir, "reth-data")
	var unwindToBlock int
	var needsUnwind bool

	// Try to find a suitable template
	templatePath, templateBlock, foundTemplate := FindBestTemplate(cfg.templateDir, cfg.startBlock)
	if foundTemplate {
		logger.Info("Found template for partition",
			"partition", cfg.partitionID,
			"template-path", templatePath,
			"template-block", templateBlock,
			"target-block", cfg.startBlock)

		// Copy from template
		if err := CopyDirectory(templatePath, destDataDir); err != nil {
			return fmt.Errorf("failed to copy template data: %w", err)
		}

		// Check if we need additional unwind
		if templateBlock > cfg.startBlock {
			needsUnwind = true
			unwindToBlock = cfg.startBlock
			logger.Info("Template block > target, will unwind",
				"partition", cfg.partitionID,
				"from-template-block", templateBlock,
				"to-target-block", cfg.startBlock)
		} else {
			needsUnwind = false
			logger.Info("Template block matches target, no unwind needed",
				"partition", cfg.partitionID)
		}
	} else {
		// No template found, use source-node-data
		if cfg.sourceNodeData == "" {
			return fmt.Errorf("no suitable template found and source-node-data not provided")
		}

		logger.Info("No template found, using source-node-data",
			"partition", cfg.partitionID,
			"source", cfg.sourceNodeData)

		if err := CopyDirectory(cfg.sourceNodeData, destDataDir); err != nil {
			return fmt.Errorf("failed to copy source data: %w", err)
		}

		needsUnwind = true
		unwindToBlock = cfg.startBlock
	}

	// Copy required configuration files and track which ones exist
	rollupExists := FileExists(cfg.rollupConfigPath)
	if rollupExists {
		if err := CopyFileIfExists(cfg.rollupConfigPath, filepath.Join(partitionDir, "rollup.json")); err != nil {
			return fmt.Errorf("failed to copy rollup.json: %w", err)
		}
	}

	jwtExists := FileExists(cfg.jwtSecretPath)
	if jwtExists {
		if err := CopyFileIfExists(cfg.jwtSecretPath, filepath.Join(partitionDir, "jwt.txt")); err != nil {
			return fmt.Errorf("failed to copy jwt.txt: %w", err)
		}
	}

	genesisExists := FileExists(cfg.genesisJsonPath)
	if genesisExists {
		if err := CopyFileIfExists(cfg.genesisJsonPath, filepath.Join(partitionDir, "genesis.json")); err != nil {
			logger.Warn("failed to copy genesis.json", "error", err)
			genesisExists = false
		}
	}

	if !rollupExists {
		return fmt.Errorf("rollup.json not found at %s", cfg.rollupConfigPath)
	}
	if !jwtExists {
		return fmt.Errorf("jwt.txt not found at %s", cfg.jwtSecretPath)
	}
	if !genesisExists {
		logger.Warn("genesis.json not found, continuing without it", "path", cfg.genesisJsonPath)
	}

	// Generate configuration files
	if err := generateConfigFiles(partitionDir, cfg.partitionID, cfg.sourceNodeUrl, cfg.startBlock, cfg.blockCount, authrpcPort, wsPort, httpPort, genesisExists, cfg.chain); err != nil {
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

	// Step 1: Run node-unwind (if needed)
	if needsUnwind {
		logger.Info("Running node-unwind", "partition", cfg.partitionID, "unwind-to", unwindToBlock)
		wd, _ := os.Getwd()
		logger.Info("Running replayor with docker compose file", "partition", cfg.partitionID, "directory", filepath.Join(partitionDir, "docker-compose.yml"), "wd", wd)

		// Update unwind target in reth.docker.env
		rethEnvPath := filepath.Join(partitionDir, "reth.docker.env")
		rethEnvContent, err := os.ReadFile(rethEnvPath)
		if err != nil {
			return fmt.Errorf("failed to read reth.docker.env: %w", err)
		}
		// Update UNWIND_TO_BLOCK value
		updatedContent := strings.ReplaceAll(string(rethEnvContent),
			fmt.Sprintf("UNWIND_TO_BLOCK=%d", cfg.startBlock),
			fmt.Sprintf("UNWIND_TO_BLOCK=%d", unwindToBlock))
		if err := os.WriteFile(rethEnvPath, []byte(updatedContent), 0644); err != nil {
			return fmt.Errorf("failed to update reth.docker.env: %w", err)
		}

		unwindCmd := exec.CommandContext(ctx, "docker", "compose", "-f", "docker-compose.yml", "up", "node-unwind")
		unwindCmd.Dir = partitionDir
		unwindCmd.Stdout = io.MultiWriter(unwindLog, os.Stdout)
		unwindCmd.Stderr = io.MultiWriter(unwindLog, os.Stderr)
		// Run the command - even if it returns success, we need to check container exit code
		unwindCmdErr := unwindCmd.Run()

		// Always check container exit code, even if docker compose command succeeded
		unwindExitCode, unwindCheckErr := checkContainerExitCode(ctx, partitionDir, "node-unwind", cfg.partitionID, logger)
		if unwindCheckErr == nil {
			if unwindExitCode != 0 {
				logger.Error("node-unwind container exited with non-zero code", "partition", cfg.partitionID, "exit-code", unwindExitCode)
				return fmt.Errorf("partition %d: node-unwind container exited with status %d", cfg.partitionID, unwindExitCode)
			}
			logger.Info("node-unwind container exited successfully", "partition", cfg.partitionID, "exit-code", unwindExitCode)
		} else {
			logger.Warn("Failed to check container exit code", "partition", cfg.partitionID, "error", unwindCheckErr)
		}

		// Also check if docker compose command itself failed
		if unwindCmdErr != nil {
			if err := checkCommandExitStatus(unwindCmdErr, fmt.Sprintf("partition-%d node-unwind", cfg.partitionID)); err != nil {
				logger.Error("node-unwind command failed", "partition", cfg.partitionID, "error", err)
				return fmt.Errorf("partition %d: node-unwind failed: %w", cfg.partitionID, err)
			}
		}
	} else {
		logger.Info("Skipping node-unwind (using pre-unwound template)", "partition", cfg.partitionID)
	}

	// Step 2: Run node (in background)
	logger.Info("Starting node", "partition", cfg.partitionID)
	nodeCmd := exec.CommandContext(ctx, "docker", "compose", "-f", "docker-compose.yml", "up", "-d", "node")
	nodeCmd.Dir = partitionDir
	nodeCmd.Stdout = io.MultiWriter(nodeLog, os.Stdout)
	nodeCmd.Stderr = io.MultiWriter(nodeLog, os.Stderr)
	if err := checkCommandExitStatus(nodeCmd.Run(), fmt.Sprintf("partition-%d node start", cfg.partitionID)); err != nil {
		logger.Error("node start command failed", "partition", cfg.partitionID, "error", err)
		return fmt.Errorf("partition %d: node start failed: %w", cfg.partitionID, err)
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
	logger.Info("Waiting for node to be ready", "partition", cfg.partitionID, "http-port", httpPort)
	if err := waitForNodeReady(ctx, logger, httpPort, 60); err != nil {
		logger.Error("node did not become ready", "partition", cfg.partitionID, "error", err)
		return fmt.Errorf("partition %d: node did not become ready: %w", cfg.partitionID, err)
	}
	logger.Info("Node is ready", "partition", cfg.partitionID)

	// Step 3: Run replayor
	logger.Info("Running replayor", "partition", cfg.partitionID)
	replayorCmd := exec.CommandContext(ctx, "docker", "compose", "-f", "docker-compose.yml", "up", "replayor")
	replayorCmd.Dir = partitionDir
	replayorCmd.Stdout = io.MultiWriter(replayorLog, os.Stdout)
	replayorCmd.Stderr = io.MultiWriter(replayorLog, os.Stderr)
	// Run the command - even if it returns success, we need to check container exit code
	replayorCmdErr := replayorCmd.Run()

	// Always check container exit code, even if docker compose command succeeded
	replayorExitCode, replayorCheckErr := checkContainerExitCode(ctx, partitionDir, "replayor", cfg.partitionID, logger)
	if replayorCheckErr == nil {
		if replayorExitCode != 0 {
			logger.Error("replayor container exited with non-zero code", "partition", cfg.partitionID, "exit-code", replayorExitCode)
			return fmt.Errorf("partition %d: replayor container exited with status %d", cfg.partitionID, replayorExitCode)
		}
		logger.Info("replayor container exited successfully", "partition", cfg.partitionID, "exit-code", replayorExitCode)
	} else {
		logger.Warn("Failed to check container exit code", "partition", cfg.partitionID, "error", replayorCheckErr)
	}

	// Also check if docker compose command itself failed
	if replayorCmdErr != nil {
		if err := checkCommandExitStatus(replayorCmdErr, fmt.Sprintf("partition-%d replayor", cfg.partitionID)); err != nil {
			logger.Error("replayor command failed", "partition", cfg.partitionID, "error", err)
			return fmt.Errorf("partition %d: replayor failed: %w", cfg.partitionID, err)
		}
	}

	// Stop node after replayor completes
	logger.Info("Stopping node", "partition", cfg.partitionID)
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
