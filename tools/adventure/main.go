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
	FlagScenario   = "scenario"
)

var (
	configPath      string
	contractAddr    string
	gaslessScenario string
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
		gaslessInitCmd(),
		gaslessBenchCmd(),
		hybridInitCmd(),
		hybridBenchCmd(),
		nativeInitCmd(),
		nativeBenchCmd(),
		simulatorInitCmd(),
		IOBenchCmd(),
		FibBenchCmd(),
		CreateBenchCmd(),
	)

	if err := rootCmd.Execute(); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
}

func simulatorInitCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "simulator-init",
		Short: "Initialize accounts for IO benchmark",
		Long: `Initialize accounts for IO benchmark.
Example:
  adventure simulator-init 100ETH -f ./testdata/config.json`,
		Args: cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			if configPath == "" {
				fmt.Println("Error: Config file (-f) is required")
				os.Exit(1)
			}

			if err := bench.SimulatorInit(args[0], configPath); err != nil {
				fmt.Printf("ERC20 initialization failed: %v\n", err)
				os.Exit(1)
			}
		},
	}

	cmd.Flags().StringVarP(&configPath, FlagConfigFile, "f", "", "Path to the benchmark configuration file")

	return cmd
}

func IOBenchCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "io-bench",
		Short: "Run io benchmark",
		Long: `Run io benchmark.

Example:
  adventure io-bench -f ./testdata/config.json.`,
		Run: func(cmd *cobra.Command, args []string) {
			if configPath == "" {
				fmt.Println("Error: Config file (-f) is required")
				os.Exit(1)
			}

			if err := bench.IOBench(configPath); err != nil {
				fmt.Printf("ERC20 benchmark failed: %v\n", err)
				os.Exit(1)
			}
		},
	}

	cmd.Flags().StringVarP(&configPath, FlagConfigFile, "f", "", "Path to the benchmark configuration file")
	return cmd
}

func FibBenchCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "fib-bench",
		Short: "Run io benchmark",
		Long: `Run io benchmark.

Example:
  adventure fib-bench -f ./testdata/config.json.`,
		Run: func(cmd *cobra.Command, args []string) {
			if configPath == "" {
				fmt.Println("Error: Config file (-f) is required")
				os.Exit(1)
			}

			if err := bench.FibBench(configPath); err != nil {
				fmt.Printf("fib benchmark failed: %v\n", err)
				os.Exit(1)
			}
		},
	}

	cmd.Flags().StringVarP(&configPath, FlagConfigFile, "f", "", "Path to the benchmark configuration file")
	return cmd
}

// CreateBench
func CreateBenchCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "create-bench",
		Short: "Run io benchmark",
		Long: `Run io benchmark.

Example:
  adventure create-bench -f ./testdata/config.json.`,
		Run: func(cmd *cobra.Command, args []string) {
			if configPath == "" {
				fmt.Println("Error: Config file (-f) is required")
				os.Exit(1)
			}

			if err := bench.CreateBench(configPath); err != nil {
				fmt.Printf("fib benchmark failed: %v\n", err)
				os.Exit(1)
			}
		},
	}

	cmd.Flags().StringVarP(&configPath, FlagConfigFile, "f", "", "Path to the benchmark configuration file")
	return cmd
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

func gaslessInitCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "gasless-init",
		Short: "Deploy an ERC20, distribute it, and register its transfer as gasless",
		Long: `Deploy an ERC20 and distribute tokens to the benchmark accounts. On the local devnet (chain id
195) it also registers that ERC20 as a gasless transfer token on the whitelist predeploy (enabling
gasless globally), using the built-in devnet owner key. On 1952 / 196 registration is skipped — the
benchmark token must already be whitelisted on-chain.

Requires senderPrivateKey (funded deployer) in the config file.

Example:
  adventure gasless-init -f ./testdata/config.json`,
		Run: func(cmd *cobra.Command, args []string) {
			if configPath == "" {
				fmt.Println("Error: Config file (-f) is required")
				os.Exit(1)
			}

			if err := bench.GaslessInit(configPath); err != nil {
				fmt.Printf("Gasless initialization failed: %v\n", err)
				os.Exit(1)
			}
		},
	}

	cmd.Flags().StringVarP(&configPath, FlagConfigFile, "f", "", "Path to the benchmark configuration file")

	return cmd
}

func gaslessBenchCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "gasless-bench",
		Short: "Run zero-gas-price (gasless) ERC20 transfer benchmark",
		Long: `Run a gasless (zero-gas-price) ERC20 stress test for one scenario (approve | transfer), as legacy
txs. The token must already be a gasless-whitelisted token (via gasless-init on devnet, or
pre-registered on 1952 / 196), or the node rejects the zero-priced txs.

Token addresses come from the config file (tokenApprove / tokenTransfer / approveSpender). Passing
--contract overrides both token addresses (the devnet path, used by the Makefile).

Example:
  adventure gasless-bench -f ./testdata/config.json --scenario transfer --contract 0x1234...`,
		Run: func(cmd *cobra.Command, args []string) {
			if configPath == "" {
				fmt.Println("Error: Config file (-f) is required")
				os.Exit(1)
			}

			if err := bench.GaslessBench(configPath, contractAddr, gaslessScenario); err != nil {
				fmt.Printf("Gasless benchmark failed: %v\n", err)
				os.Exit(1)
			}
		},
	}

	cmd.Flags().StringVarP(&configPath, FlagConfigFile, "f", "", "Path to the benchmark configuration file")
	cmd.Flags().StringVar(&contractAddr, FlagContract, "", "ERC20 address override for both approve/transfer tokens (devnet)")
	cmd.Flags().StringVar(&gaslessScenario, FlagScenario, "transfer", "Gasless scenario: approve | transfer")

	return cmd
}

func hybridInitCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "hybrid-init <amount>",
		Short: "Provision accounts for the hybrid (gasless + normal ERC20) benchmark",
		Long: `Deploy an ERC20, distribute native gas AND the ERC20 to every benchmark account, and (on the local
devnet, chain id 195) register the ERC20 as a gasless transfer token. Accounts end up able to send
both a zero-gas-price gasless transfer and a normal, gas-paying ERC20 transfer of that token.

Amount format: Must end with 'ETH' suffix, e.g., '1ETH', '100ETH' (native gas per account).

Example:
  adventure hybrid-init 10000ETH -f ./testdata/config.json`,
		Args: cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			if configPath == "" {
				fmt.Println("Error: Config file (-f) is required")
				os.Exit(1)
			}

			if err := bench.HybridInit(args[0], configPath); err != nil {
				fmt.Printf("Hybrid initialization failed: %v\n", err)
				os.Exit(1)
			}
		},
	}

	cmd.Flags().StringVarP(&configPath, FlagConfigFile, "f", "", "Path to the benchmark configuration file")

	return cmd
}

func hybridBenchCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "hybrid-bench",
		Short: "Run the alternating gasless + normal ERC20 transfer benchmark",
		Long: `Run a hybrid stress test that interleaves, across the benchmark accounts, one zero-gas-price
(gasless) ERC20 transfer and one normal, gas-paying ERC20 transfer of the same token. The token must
already be gasless-whitelisted (via hybrid-init on devnet, or pre-registered on 1952 / 196).

The token comes from the config file (tokenTransfer); passing --contract overrides it (the devnet
path). On 1952 / 196 set tokenTransfer in config and omit --contract.

Example:
  adventure hybrid-bench -f ./testdata/config.json --contract 0x1234...`,
		Run: func(cmd *cobra.Command, args []string) {
			if configPath == "" {
				fmt.Println("Error: Config file (-f) is required")
				os.Exit(1)
			}

			if err := bench.HybridBench(configPath, contractAddr); err != nil {
				fmt.Printf("Hybrid benchmark failed: %v\n", err)
				os.Exit(1)
			}
		},
	}

	cmd.Flags().StringVarP(&configPath, FlagConfigFile, "f", "", "Path to the benchmark configuration file")
	cmd.Flags().StringVar(&contractAddr, FlagContract, "", "ERC20 token override (devnet); defaults to config tokenTransfer")

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
