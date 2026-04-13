package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/urfave/cli/v2"
)

// Shared flags used by both run and gen-template commands
var (
	SourceNodeDataFlag = &cli.StringFlag{
		Name:    "source-node-data",
		Usage:   "The source data directory to copy for each partition",
		EnvVars: []string{"SOURCE_NODE_DATA"},
	}
	SegmentsFlag = &cli.StringFlag{
		Name:     "segments",
		Usage:    "Block number segments, e.g. --segments=0-10,10-20,20-30",
		Required: true,
		EnvVars:  []string{"SEGMENTS"},
	}
	WorkDirFlag = &cli.StringFlag{
		Name:    "work-dir",
		Usage:   "Working directory to create partition directories",
		Value:   "./multi-replayor-work",
		EnvVars: []string{"WORK_DIR"},
	}
	RollupConfigPathFlag = &cli.StringFlag{
		Name:    "rollup-config-path",
		Usage:   "Path to rollup.json file",
		Value:   "./rollup.json",
		EnvVars: []string{"ROLLUP_CONFIG_PATH"},
	}
	JwtSecretPathFlag = &cli.StringFlag{
		Name:    "jwt-secret-path",
		Usage:   "Path to jwt.txt file",
		Value:   "./jwt.txt",
		EnvVars: []string{"JWT_SECRET_PATH"},
	}
	GenesisJsonPathFlag = &cli.StringFlag{
		Name:    "genesis-json-path",
		Usage:   "Path to genesis.json file (optional)",
		Value:   "./genesis.json",
		EnvVars: []string{"GENESIS_JSON_PATH"},
	}
	ChainFlag = &cli.StringFlag{
		Name:    "chain",
		Usage:   "empty or xlayer-testnet or xlayer-mainnet",
		Value:   "",
		EnvVars: []string{"CHAIN"},
	}
)

// SharedFlags returns the common flags used by multiple commands
func SharedFlags() []cli.Flag {
	return []cli.Flag{
		SourceNodeDataFlag,
		SegmentsFlag,
		WorkDirFlag,
		RollupConfigPathFlag,
		JwtSecretPathFlag,
		GenesisJsonPathFlag,
		ChainFlag,
	}
}

// PartitionRange represents a block range for a partition
type PartitionRange struct {
	ID         int
	StartBlock int
	EndBlock   int
	BlockCount int
}

// ParseSegments parses a segments string like "0-10,10-20,20-30" into []PartitionRange
func ParseSegments(segmentsStr string) ([]PartitionRange, error) {
	parts := strings.Split(segmentsStr, ",")
	if len(parts) == 0 {
		return nil, fmt.Errorf("segments string is empty")
	}

	ranges := make([]PartitionRange, 0, len(parts))
	for i, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		dashIdx := strings.Index(part, "-")
		if dashIdx <= 0 {
			return nil, fmt.Errorf("invalid segment format %q, expected start-end (e.g. 0-10)", part)
		}
		startStr := part[:dashIdx]
		endStr := part[dashIdx+1:]

		startBlock, err := strconv.Atoi(startStr)
		if err != nil {
			return nil, fmt.Errorf("invalid start block in segment %q: %w", part, err)
		}
		endBlock, err := strconv.Atoi(endStr)
		if err != nil {
			return nil, fmt.Errorf("invalid end block in segment %q: %w", part, err)
		}
		if startBlock < 0 {
			return nil, fmt.Errorf("start block must be non-negative in segment %q", part)
		}
		if endBlock <= startBlock {
			return nil, fmt.Errorf("end block must be greater than start block in segment %q", part)
		}

		ranges = append(ranges, PartitionRange{
			ID:         i,
			StartBlock: startBlock,
			EndBlock:   endBlock,
			BlockCount: endBlock - startBlock,
		})
	}

	if len(ranges) == 0 {
		return nil, fmt.Errorf("no valid segments found")
	}

	return ranges, nil
}

// GetUniqueTemplateBlocks returns unique block numbers for template generation
// This includes all partition start blocks plus end blocks
func GetUniqueTemplateBlocks(ranges []PartitionRange) []int {
	// Use a map to deduplicate
	blockSet := make(map[int]bool)
	for _, r := range ranges {
		blockSet[r.StartBlock] = true
		blockSet[r.EndBlock] = true
	}

	// Convert to sorted slice
	blocks := make([]int, 0, len(blockSet))
	for b := range blockSet {
		blocks = append(blocks, b)
	}
	sort.Ints(blocks)

	return blocks
}

// TemplateDir represents a template directory with its block number
type TemplateDir struct {
	Path        string
	BlockNumber int
}

// FindTemplateDirectories scans a directory for reth-{block} template directories
func FindTemplateDirectories(dir string) ([]TemplateDir, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	pattern := regexp.MustCompile(`^reth-(\d+)$`)
	var templates []TemplateDir

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		matches := pattern.FindStringSubmatch(entry.Name())
		if matches == nil {
			continue
		}

		blockNum, err := strconv.Atoi(matches[1])
		if err != nil {
			continue
		}

		templates = append(templates, TemplateDir{
			Path:        filepath.Join(dir, entry.Name()),
			BlockNumber: blockNum,
		})
	}

	// Sort by block number
	sort.Slice(templates, func(i, j int) bool {
		return templates[i].BlockNumber < templates[j].BlockNumber
	})

	return templates, nil
}

// FindBestTemplate finds the smallest template directory with block number >= targetBlock
// Returns the template path, block number, and whether a template was found
func FindBestTemplate(templateDir string, targetBlock int) (string, int, bool) {
	templates, err := FindTemplateDirectories(templateDir)
	if err != nil || len(templates) == 0 {
		return "", 0, false
	}

	// Find the smallest template >= targetBlock
	for _, t := range templates {
		if t.BlockNumber >= targetBlock {
			return t.Path, t.BlockNumber, true
		}
	}

	return "", 0, false
}

// TemplateDataDir returns the path to the template data directory
func TemplateDataDir(workDir string, blockNumber int) string {
	return filepath.Join(workDir, fmt.Sprintf("reth-%d", blockNumber))
}

// FileExists checks if a file exists
func FileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// CopyFileIfExists copies a file from src to dst if it exists
func CopyFileIfExists(src, dst string) error {
	if !FileExists(src) {
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

// CopyDirectory copies a directory recursively from src to dst
func CopyDirectory(src, dst string) error {
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

