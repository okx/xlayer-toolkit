package bench

import (
	"context"
	"errors"
	"fmt"
	"log"
	"math/big"
	"strings"
	"time"

	ethcmn "github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/okx/adventure/utils"
)

// ========================================
// Hybrid (gasless + normal ERC20) Benchmark
// ========================================
//
// The hybrid bench interleaves two transaction types against a single ERC20:
//   - a zero-gas-price (gasless) transfer(deadAddr, 0)   — free via the gasless whitelist
//   - a normal, gas-paying transfer(fixedAddr, 1)        — pays the configured gas price
//
// RunTxs's callback returns both templates and the batch runner assigns them round-robin across the
// benchmark accounts, so the submitted tx stream alternates gasless / normal. Every account therefore
// needs both ERC20 balance (both legs send transfers of the token) and native balance (the normal leg
// pays gas), which is exactly what HybridInit provisions.

// HybridInit prepares the benchmark accounts for the hybrid bench. It deploys an ERC20, distributes
// native gas AND the ERC20 to every account, and — on the local devnet (chain id 195) — registers the
// ERC20 as a gasless transfer token on the whitelist predeploy (enabling gasless globally). On
// 1952 / 196 registration is skipped: the ERC20 must already be whitelisted on-chain.
//
// amountStr is the native amount distributed to each account (e.g. "10000ETH"), funding the
// gas-paying normal-transfer leg.
func HybridInit(amountStr, configPath string) error {
	if err := loadConfig(configPath); err != nil {
		return err
	}
	if utils.TransferCfg.SenderPrivateKey == "" {
		return errors.New("senderPrivateKey must be set in config file")
	}

	amount, err := parseAmountWithETH(amountStr)
	if err != nil {
		return fmt.Errorf("failed to parse amount: %v", err)
	}

	rpcURL := utils.TransferCfg.Rpc[0]

	senderKey, err := crypto.HexToECDSA(strings.TrimPrefix(utils.TransferCfg.SenderPrivateKey, "0x"))
	if err != nil {
		return fmt.Errorf("failed to parse senderPrivateKey: %v", err)
	}

	// Reuse the accounts loadConfig already loaded (sliced by accountOffset) — no second file read.
	hexAddrs := loadAccountAddresses(utils.TransferCfg.BenchmarkAccounts)
	if len(hexAddrs) == 0 {
		return errors.New("no benchmark accounts loaded")
	}

	cli := utils.NewClient(rpcURL)
	chainID, err := cli.ChainID(context.Background())
	if err != nil {
		return fmt.Errorf("failed to query chainId: %v", err)
	}
	sender := utils.GetEthAddressFromPK(senderKey)

	// 1. Deploy BatchTransfer (native) and distribute native gas to every account (needed for the
	//    normal, gas-paying ERC20 transfer leg).
	nonce, err := cli.QueryNonce(sender.String())
	if err != nil {
		return fmt.Errorf("failed to query nonce: %v", err)
	}
	nativeBT, err := deployBTNative(cli, senderKey, nonce)
	if err != nil {
		return fmt.Errorf("failed to deploy BatchTransfer native: %v", err)
	}
	time.Sleep(time.Second * 5)
	if err := transfersNative(cli, senderKey, nonce+1, nativeBT, amount, hexAddrs); err != nil {
		return fmt.Errorf("failed to distribute native tokens: %v", err)
	}
	time.Sleep(time.Second * 5)

	// 2. Deploy ERC20.
	nonce, err = cli.QueryNonce(sender.String())
	if err != nil {
		return fmt.Errorf("failed to query nonce: %v", err)
	}
	erc20Addr, err := deployERC20(cli, senderKey, nonce)
	if err != nil {
		return fmt.Errorf("failed to deploy ERC20: %v", err)
	}
	time.Sleep(time.Second * 5)

	// No ERC20 distribution: both bench legs send transfer(deadAddr, 0), which never touches balance,
	// so accounts only need native gas (for the normal leg) — already funded above.

	// 3. Register the ERC20 as a gasless transfer token (devnet only — see GaslessInit).
	if chainID.Int64() == GaslessDevnetChainID {
		ownerKey, err := crypto.HexToECDSA(strings.TrimPrefix(GaslessDevnetOwnerPrivateKey, "0x"))
		if err != nil {
			return fmt.Errorf("failed to parse devnet gasless owner key: %v", err)
		}
		approveSpender := utils.TransferCfg.ApproveSpender
		if approveSpender == "" {
			approveSpender = DefaultApproveSpender
		}
		if err := registerGaslessTransferToken(cli, ownerKey, erc20Addr, ethcmn.HexToAddress(approveSpender), chainID.Int64()); err != nil {
			return fmt.Errorf("failed to register gasless transfer token: %v", err)
		}
		log.Printf("✅ Hybrid init done. ERC20=%s (gasless-registered + native gas distributed); run: adventure hybrid-bench -f <cfg> --contract %s\n",
			erc20Addr, erc20Addr)
	} else {
		log.Printf("✅ Hybrid init done. ERC20=%s deployed, native gas distributed (chain id %d: gasless registration skipped — token must already be whitelisted on-chain)\n",
			erc20Addr, chainID.Int64())
	}
	return nil
}

// HybridBench runs the alternating gasless + normal ERC20 transfer benchmark. Both legs target a
// single ERC20: it comes from the config file (tokenTransfer), and passing --contract overrides it
// (the devnet path, set by the Makefile to HybridInit's freshly deployed token). On non-devnet chains
// (1952 / 196) set tokenTransfer in config to an already gasless-whitelisted token and omit --contract.
func HybridBench(configPath, contractAddr string) error {
	if configPath == "" {
		return errors.New("configPath must not be empty")
	}
	if err := loadConfig(configPath); err != nil {
		return err
	}

	tokenAddr := utils.TransferCfg.TokenTransfer
	if contractAddr != "" {
		tokenAddr = contractAddr
	}
	if tokenAddr == "" {
		return errors.New("token address must be set (config tokenTransfer or --contract)")
	}
	token := ethcmn.HexToAddress(tokenAddr)

	// Both legs are transfer(deadAddr, 0): amount 0 so they never revert on balance and need no token
	// distribution — the legs differ only in gas price.
	_, transferData, err := buildGaslessTxData("transfer", tokenAddr, DefaultApproveSpender, tokenAddr)
	if err != nil {
		return fmt.Errorf("failed to build transfer tx data: %v", err)
	}

	// Gasless leg: gasPrice 0 — free via the whitelist.
	gaslessParam := utils.NewTxParam(&token, nil, GaslessBenchTxGasLimit, big.NewInt(0), transferData)

	// Normal leg: same calldata at the configured gas price — pays gas.
	gasPrice := utils.ParseGasPriceToBigInt(utils.TransferCfg.GasPriceGwei, 9)
	erc20Param := utils.NewTxParam(&token, nil, uint64(100000), gasPrice, transferData)

	log.Printf("hybrid-bench token=%s (alternating gasless transfer + normal erc20 transfer)\n", token.Hex())

	// Returning both templates makes the batch runner alternate them across accounts, so the submitted
	// tx stream interleaves one gasless transfer, one normal transfer, repeating.
	utils.RunTxs(
		func(_ ethcmn.Address) []utils.TxParam {
			return []utils.TxParam{gaslessParam, erc20Param}
		},
	)

	return nil
}
