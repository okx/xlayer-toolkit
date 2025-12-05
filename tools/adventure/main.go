package main

import (
	"fmt"
	"log"
	"os"

	"github.com/spf13/cobra"

	"github.com/okx/adventure/bench"
)

func init() {
	log.SetOutput(os.Stdout)
	log.SetFlags(log.LstdFlags)
}

const (
	FlagConfigFile = "config-file"
	FlagContract   = "contract"
)

var (
	configPath   string
	contractAddr string
)

func main() {
	rootCmd := &cobra.Command{
		Use:   "adventure",
		Short: "X Layer stress testing tool for ERC20 and Native Token",
		Long:  `A command-line tool for stress testing X Layer with ERC20 token and Native token transfers.`,
	}

	rootCmd.AddCommand(
		erc20InitCmd(),
		erc20BenchCmd(),
		nativeInitCmd(),
		nativeBenchCmd(),
	)

	if err := rootCmd.Execute(); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
}

func erc20InitCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "erc20-init <amount>",
		Short: "Deploy ERC20 and BatchTransfer contracts, distribute tokens",
		Long: `Deploy ERC20 contract, BatchTransfer contract, and distribute tokens to accounts.

Amount format: Must end with 'ETH' suffix, e.g., '1ETH', '0.01ETH', '100ETH'

Example:
  adventure erc20-init 100ETH -f ./testdata/config.json`,
		Args: cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			if configPath == "" {
				fmt.Println("Error: Config file (-f) is required")
				os.Exit(1)
			}

			if err := bench.Erc20Init(args[0], configPath); err != nil {
				fmt.Printf("ERC20 initialization failed: %v\n", err)
				os.Exit(1)
			}
		},
	}

	cmd.Flags().StringVarP(&configPath, FlagConfigFile, "f", "", "Path to the benchmark configuration file")

	return cmd
}

func erc20BenchCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "erc20-bench",
		Short: "Run ERC20 transfer benchmark",
		Long: `Run ERC20 token transfer stress test using configuration file.

Example:
  adventure erc20-bench -f ./testdata/config.json --contract 0x1234...`,
		Run: func(cmd *cobra.Command, args []string) {
			if configPath == "" {
				fmt.Println("Error: Config file (-f) is required")
				os.Exit(1)
			}
			if contractAddr == "" {
				fmt.Println("Error: Contract address (--contract) is required")
				os.Exit(1)
			}

			if err := bench.Erc20Bench(configPath, contractAddr); err != nil {
				fmt.Printf("ERC20 benchmark failed: %v\n", err)
				os.Exit(1)
			}
		},
	}

	cmd.Flags().StringVarP(&configPath, FlagConfigFile, "f", "", "Path to the benchmark configuration file")
	cmd.Flags().StringVar(&contractAddr, FlagContract, "", "ERC20 contract address")

	return cmd
}

func nativeInitCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "native-init <amount>",
		Short: "Deploy BatchTransfer contract and distribute native tokens",
		Long: `Deploy BatchTransfer contract and distribute native tokens to accounts.

Amount format: Must end with 'ETH' suffix, e.g., '1ETH', '0.01ETH', '100ETH'

Example:
  adventure native-init 100ETH -f ./testdata/config.json`,
		Args: cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			if configPath == "" {
				fmt.Println("Error: Config file (-f) is required")
				os.Exit(1)
			}

			if err := bench.NativeInit(args[0], configPath); err != nil {
				fmt.Printf("Native token initialization failed: %v\n", err)
				os.Exit(1)
			}
		},
	}

	cmd.Flags().StringVarP(&configPath, FlagConfigFile, "f", "", "Path to the benchmark configuration file")

	return cmd
}

func nativeBenchCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "native-bench",
		Short: "Run native token transfer benchmark",
		Long: `Run native token transfer stress test using configuration file.

Example:
  adventure native-bench -f ./testdata/config.json`,
		Run: func(cmd *cobra.Command, args []string) {
			if configPath == "" {
				fmt.Println("Error: Config file (-f) is required")
				os.Exit(1)
			}

			if err := bench.NativeBench(configPath); err != nil {
				fmt.Printf("Native token benchmark failed: %v\n", err)
				os.Exit(1)
			}
		},
	}

	cmd.Flags().StringVarP(&configPath, FlagConfigFile, "f", "", "Path to the benchmark configuration file")

	return cmd
}
