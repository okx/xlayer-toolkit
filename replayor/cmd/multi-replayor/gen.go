package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"

	oplog "github.com/ethereum-optimism/optimism/op-service/log"
	"github.com/ethereum/go-ethereum/log"
	"github.com/urfave/cli/v2"
)

// GenTemplateCommand returns the gen-template subcommand
func GenTemplateCommand() *cli.Command {
	flags := SharedFlags()
	flags = append(flags, oplog.CLIFlags("MULTI_REPLAYOR")...)

	return &cli.Command{
		Name:  "gen-template",
		Usage: "Generate reth data templates for each partition start block",
		Flags: flags,
		Action: func(cliCtx *cli.Context) error {
			return genTemplateAction(cliCtx)
		},
	}
}

func genTemplateAction(cliCtx *cli.Context) error {
	logger := oplog.NewLogger(oplog.AppOut(cliCtx), oplog.ReadCLIConfig(cliCtx))

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
	if sourceNodeData == "" {
		return fmt.Errorf("--source-node-data is required")
	}
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

	// Calculate unique template blocks
	templateBlocks := GetUniqueTemplateBlocks(from, to, partition)

	logger.Info("Starting template generation",
		"source-node-data", sourceNodeData,
		"from", from,
		"to", to,
		"partition", partition,
		"work-dir", workDir,
		"template-blocks", templateBlocks)

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
		logger.Info("Received shutdown signal, stopping template generation")
		cancel()
	}()

	// Generate templates in parallel
	var wg sync.WaitGroup
	var mu sync.Mutex
	var errors []error

	for i, blockNum := range templateBlocks {
		wg.Add(1)
		go func(idx int, targetBlock int) {
			defer wg.Done()

			logger.Info("Generating template",
				"index", idx,
				"target-block", targetBlock)

			err := generateTemplate(ctx, logger, genTemplateConfig{
				workDir:          workDir,
				templateID:       idx,
				sourceNodeData:   sourceNodeData,
				targetBlock:      targetBlock,
				rollupConfigPath: rollupConfigPath,
				jwtSecretPath:    jwtSecretPath,
				genesisJsonPath:  genesisJsonPath,
				chain:            chain,
			})
			if err != nil {
				mu.Lock()
				errors = append(errors, fmt.Errorf("template %d (block %d) failed: %w", idx, targetBlock, err))
				mu.Unlock()
				logger.Error("Template generation failed",
					"index", idx,
					"target-block", targetBlock,
					"error", err)
			} else {
				logger.Info("Template generated successfully",
					"index", idx,
					"target-block", targetBlock)
			}
		}(i, blockNum)
	}

	// Wait for all template generations to complete
	wg.Wait()

	if len(errors) > 0 {
		logger.Error("Some template generations failed", "error-count", len(errors))
		for _, err := range errors {
			logger.Error("Error", "error", err)
		}
		return fmt.Errorf("%d template generation(s) failed", len(errors))
	}

	logger.Info("All templates generated successfully",
		"template-count", len(templateBlocks),
		"work-dir", workDir)
	return nil
}

type genTemplateConfig struct {
	workDir          string
	templateID       int
	sourceNodeData   string
	targetBlock      int
	rollupConfigPath string
	jwtSecretPath    string
	genesisJsonPath  string
	chain            string
}

func generateTemplate(ctx context.Context, logger log.Logger, cfg genTemplateConfig) error {
	// Template directory is named reth-{blockNumber}
	templateDir := TemplateDataDir(cfg.workDir, cfg.targetBlock)

	// Check if template already exists
	if FileExists(templateDir) {
		logger.Info("Template already exists, skipping",
			"template-id", cfg.templateID,
			"target-block", cfg.targetBlock,
			"path", templateDir)
		return nil
	}

	// Create a temporary working directory for this template generation
	tempDir := filepath.Join(cfg.workDir, fmt.Sprintf(".gen-template-%d", cfg.templateID))
	if err := os.MkdirAll(tempDir, 0755); err != nil {
		return fmt.Errorf("failed to create temp directory: %w", err)
	}
	defer os.RemoveAll(tempDir) // Clean up temp directory when done

	// Calculate ports (unique per template to avoid conflicts)
	authrpcPort := 17700 + cfg.templateID
	wsPort := 17800 + cfg.templateID
	httpPort := 17900 + cfg.templateID

	logger.Info("Setting up template generation",
		"template-id", cfg.templateID,
		"target-block", cfg.targetBlock,
		"temp-dir", tempDir,
		"authrpc-port", authrpcPort)

	// Copy source data to temp directory
	tempDataDir := filepath.Join(tempDir, "reth-data")
	if err := CopyDirectory(cfg.sourceNodeData, tempDataDir); err != nil {
		return fmt.Errorf("failed to copy source data: %w", err)
	}

	// Copy required configuration files
	rollupExists := FileExists(cfg.rollupConfigPath)
	if rollupExists {
		if err := CopyFileIfExists(cfg.rollupConfigPath, filepath.Join(tempDir, "rollup.json")); err != nil {
			return fmt.Errorf("failed to copy rollup.json: %w", err)
		}
	}

	jwtExists := FileExists(cfg.jwtSecretPath)
	if jwtExists {
		if err := CopyFileIfExists(cfg.jwtSecretPath, filepath.Join(tempDir, "jwt.txt")); err != nil {
			return fmt.Errorf("failed to copy jwt.txt: %w", err)
		}
	}

	genesisExists := FileExists(cfg.genesisJsonPath)
	if genesisExists {
		if err := CopyFileIfExists(cfg.genesisJsonPath, filepath.Join(tempDir, "genesis.json")); err != nil {
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

	// Generate configuration files for unwind
	if err := generateTemplateConfigFiles(tempDir, cfg.templateID, cfg.targetBlock, authrpcPort, wsPort, httpPort, genesisExists, cfg.chain); err != nil {
		return fmt.Errorf("failed to generate config files: %w", err)
	}

	// Setup log file
	unwindLog, err := os.Create(filepath.Join(tempDir, "unwind.log"))
	if err != nil {
		return fmt.Errorf("failed to create unwind.log: %w", err)
	}
	defer unwindLog.Close()

	// Run unwind
	logger.Info("Running unwind for template",
		"template-id", cfg.templateID,
		"target-block", cfg.targetBlock)

	unwindCmd := exec.CommandContext(ctx, "docker", "compose", "-f", "docker-compose.yml", "up", "node-unwind")
	unwindCmd.Dir = tempDir
	unwindCmd.Stdout = io.MultiWriter(unwindLog, os.Stdout)
	unwindCmd.Stderr = io.MultiWriter(unwindLog, os.Stderr)
	unwindCmdErr := unwindCmd.Run()

	// Check container exit code
	unwindExitCode, unwindCheckErr := checkContainerExitCode(ctx, tempDir, "node-unwind", cfg.templateID, logger)
	if unwindCheckErr == nil {
		if unwindExitCode != 0 {
			logger.Error("node-unwind container exited with non-zero code",
				"template-id", cfg.templateID,
				"exit-code", unwindExitCode)
			return fmt.Errorf("template %d: node-unwind container exited with status %d", cfg.templateID, unwindExitCode)
		}
		logger.Info("node-unwind container exited successfully",
			"template-id", cfg.templateID,
			"exit-code", unwindExitCode)
	} else {
		logger.Warn("Failed to check container exit code",
			"template-id", cfg.templateID,
			"error", unwindCheckErr)
	}

	if unwindCmdErr != nil {
		if err := checkCommandExitStatus(unwindCmdErr, fmt.Sprintf("template-%d node-unwind", cfg.templateID)); err != nil {
			logger.Error("node-unwind command failed",
				"template-id", cfg.templateID,
				"error", err)
			return fmt.Errorf("template %d: node-unwind failed: %w", cfg.templateID, err)
		}
	}

	// Clean up docker compose resources
	stopCmd := exec.CommandContext(ctx, "docker", "compose", "-f", "docker-compose.yml", "down")
	stopCmd.Dir = tempDir
	stopCmd.Run() // Ignore errors on cleanup

	// Move the reth-data to the final template directory
	if err := os.Rename(tempDataDir, templateDir); err != nil {
		// If rename fails (e.g., cross-device), try copy and delete
		if err := CopyDirectory(tempDataDir, templateDir); err != nil {
			return fmt.Errorf("failed to move reth-data to template directory: %w", err)
		}
		os.RemoveAll(tempDataDir)
	}

	logger.Info("Template generated",
		"template-id", cfg.templateID,
		"target-block", cfg.targetBlock,
		"path", templateDir)

	return nil
}

func generateTemplateConfigFiles(tempDir string, templateID int, targetBlock, authrpcPort, wsPort, httpPort int, genesisExists bool, chain string) error {
	// Generate docker-compose.yml
	dockerComposePath := filepath.Join(tempDir, "docker-compose.yml")
	dockerComposeContent := dockerComposeTemplate

	// Replace ports
	dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "9123:9123", fmt.Sprintf("%d:%d", httpPort, httpPort))
	dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "8553:8553", fmt.Sprintf("%d:%d", authrpcPort, authrpcPort))

	// Replace network name
	dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "${DOCKER_NETWORK:-dev-replayor}", fmt.Sprintf("gen-template-%d", templateID))

	// Handle genesis.json
	if !genesisExists {
		dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "      - ${GENESIS_JSON_PATH:-./genesis.json}:/app/genesis.json:ro\n", "")
		dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "- ${GENESIS_JSON_PATH:-./genesis.json}:/app/genesis.json:ro", "")
		dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "${GENESIS_JSON_PATH:-./genesis.json}", "")
	} else {
		dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "${GENESIS_JSON_PATH:-./genesis.json}", "./genesis.json")
	}

	// Ensure other paths are relative
	dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "${ROLLUP_JSON_PATH:-./rollup.json}", "./rollup.json")
	dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "${JWT_TXT_PATH:-./jwt.txt}", "./jwt.txt")
	dockerComposeContent = strings.ReplaceAll(dockerComposeContent, "${RETH_DATA_PATH:-./reth-data}", "./reth-data")

	if err := os.WriteFile(dockerComposePath, []byte(dockerComposeContent), 0644); err != nil {
		return fmt.Errorf("failed to write docker-compose.yml: %w", err)
	}

	// Generate reth.docker.env
	rethEnvPath := filepath.Join(tempDir, "reth.docker.env")
	rethEnvContent := strings.ReplaceAll(rethDockerEnvTemplate, "RETH_HTTP_PORT=9123", fmt.Sprintf("RETH_HTTP_PORT=%d", httpPort))
	rethEnvContent = strings.ReplaceAll(rethEnvContent, "RETH_WS_PORT=9124", fmt.Sprintf("RETH_WS_PORT=%d", wsPort))
	rethEnvContent = strings.ReplaceAll(rethEnvContent, "RETH_AUTHRPC_PORT=8553", fmt.Sprintf("RETH_AUTHRPC_PORT=%d", authrpcPort))
	rethEnvContent = strings.ReplaceAll(rethEnvContent, "RETH_DATA_DIR=./reth-data", "RETH_DATA_DIR=./reth-data")
	if chain == "xlayer-testnet" || chain == "xlayer-mainnet" {
		rethEnvContent = strings.ReplaceAll(rethEnvContent, "RETH_CHAIN=./genesis.json", fmt.Sprintf("RETH_CHAIN=%s", chain))
	}
	// Set unwind target block
	rethEnvContent = strings.ReplaceAll(rethEnvContent, "UNWIND_TO_BLOCK=8602500", fmt.Sprintf("UNWIND_TO_BLOCK=%d", targetBlock))
	if err := os.WriteFile(rethEnvPath, []byte(rethEnvContent), 0644); err != nil {
		return fmt.Errorf("failed to write reth.docker.env: %w", err)
	}

	// Copy shell scripts
	scripts := map[string]string{
		"unwind.sh":   unwindShTemplate,
		"reth.sh":     rethShTemplate,
		"replayor.sh": replayorShTemplate,
	}

	for name, content := range scripts {
		scriptPath := filepath.Join(tempDir, name)
		if err := os.WriteFile(scriptPath, []byte(content), 0755); err != nil {
			return fmt.Errorf("failed to write %s: %w", name, err)
		}
	}

	// Copy Dockerfile
	dockerfilePath := filepath.Join(tempDir, "Dockerfile")
	if err := os.WriteFile(dockerfilePath, []byte(dockerfileTemplate), 0644); err != nil {
		return fmt.Errorf("failed to write Dockerfile: %w", err)
	}

	return nil
}
