package bench

import (
	"crypto/ecdsa"
	"errors"
	"fmt"
	"log"
	"math/big"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	ethcmn "github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/okx/adventure/utils"
)

// ========================================
// Gasless (zero-gas-price) ERC20 Benchmark
// ========================================
//
// The XLayer gasless whitelist predeploy decides, per tx, whether a zero-priced tx may execute
// without paying fees. `gasless-init` deploys an ERC20, distributes it to the benchmark accounts,
// and registers that ERC20 as a gasless transfer token (so `transfer(address,uint256)` calls to it
// are gasless). `gasless-bench` then has the benchmark accounts send zero-gas-price ERC20 transfers
// to that contract — the gasless path under load.

// GaslessWhitelistAddr is the XLayer gasless whitelist predeploy address (chain id 195 / devnet).
// Mirrors XLAYER_DEVNET_GASLESS_CONTRACT in alloy-op-evm.
const GaslessWhitelistAddr = "0x4200000000000000000000000000000000000700"

// GaslessTransferGasLimit is the per-tx gas allowance registered for the ERC20 transfer rule.
const GaslessTransferGasLimit uint64 = 1000000

// GaslessBenchTxGasLimit is the gas limit set on each benchmark gasless transfer.
const GaslessBenchTxGasLimit uint64 = 100000

// GaslessWhitelistABI is the subset of contracts-bedrock src/L2/XlayerGaslessWhitelist.sol needed to
// enable gasless and register an ERC20 as a gasless transfer token.
const GaslessWhitelistABI = `[
	{"inputs":[{"internalType":"bool","name":"enabled","type":"bool"}],"name":"setGaslessEnabled","outputs":[],"stateMutability":"nonpayable","type":"function"},
	{"inputs":[{"internalType":"address","name":"token","type":"address"},{"internalType":"bool","name":"allowed","type":"bool"},{"internalType":"uint64","name":"gasLimit","type":"uint64"}],"name":"setGaslessTransferToken","outputs":[],"stateMutability":"nonpayable","type":"function"}
]`

// GaslessInit deploys an ERC20, distributes it to the benchmark accounts, and registers that ERC20
// as a gasless transfer token on the whitelist predeploy (enabling gasless globally if needed).
func GaslessInit(configPath string) error {
	if err := loadConfig(configPath); err != nil {
		return err
	}
	if utils.TransferCfg.SenderPrivateKey == "" {
		return errors.New("senderPrivateKey must be set in config file")
	}
	if utils.TransferCfg.GaslessOwnerPrivateKey == "" {
		return errors.New("gaslessOwnerPrivateKey (the gasless whitelist owner) must be set in config file")
	}

	rpcURL := utils.TransferCfg.Rpc[0]
	accountsFile, err := GetConfigFilePath(utils.TransferCfg.Accounts)
	if err != nil {
		return fmt.Errorf("failed to get accounts file path: %v", err)
	}

	senderKey, err := crypto.HexToECDSA(strings.TrimPrefix(utils.TransferCfg.SenderPrivateKey, "0x"))
	if err != nil {
		return fmt.Errorf("failed to parse senderPrivateKey: %v", err)
	}
	ownerKey, err := crypto.HexToECDSA(strings.TrimPrefix(utils.TransferCfg.GaslessOwnerPrivateKey, "0x"))
	if err != nil {
		return fmt.Errorf("failed to parse gaslessOwnerPrivateKey: %v", err)
	}

	hexAddrs := loadAccountAddresses(accountsFile)
	if len(hexAddrs) == 0 {
		return errors.New("no benchmark accounts loaded")
	}

	cli := utils.NewClient(rpcURL)
	sender := utils.GetEthAddressFromPK(senderKey)

	// 1. Deploy ERC20.
	nonce, err := cli.QueryNonce(sender.String())
	if err != nil {
		return fmt.Errorf("failed to query nonce: %v", err)
	}
	erc20Addr, err := deployERC20(cli, senderKey, nonce)
	if err != nil {
		return fmt.Errorf("failed to deploy ERC20: %v", err)
	}
	time.Sleep(time.Second * 5)

	// 2. Deploy BatchTransfer (ERC20) used to distribute tokens to the benchmark accounts.
	nonce, err = cli.QueryNonce(sender.String())
	if err != nil {
		return fmt.Errorf("failed to query nonce: %v", err)
	}
	bterc20Addr, err := deployBTERC20(cli, senderKey, nonce)
	if err != nil {
		return fmt.Errorf("failed to deploy BatchTransfer ERC20: %v", err)
	}
	time.Sleep(time.Second * 5)

	// 3. Approve the BatchTransfer contract to move the sender's tokens.
	nonce, err = cli.QueryNonce(sender.String())
	if err != nil {
		return fmt.Errorf("failed to query nonce: %v", err)
	}
	if err := sendApprove(cli, senderKey, nonce, erc20Addr, TotalSupplyAmount, bterc20Addr); err != nil {
		return fmt.Errorf("failed to approve ERC20: %v", err)
	}
	time.Sleep(time.Second * 5)

	// 4. Distribute tokens so each benchmark account can send transfers.
	nonce, err = cli.QueryNonce(sender.String())
	if err != nil {
		return fmt.Errorf("failed to query nonce: %v", err)
	}
	accBalance := TotalSupplyAmount.Int64() / int64(len(hexAddrs))
	if accBalance == 0 {
		accBalance = 1
	}
	if err := transferERC20(cli, senderKey, nonce, bterc20Addr, erc20Addr, big.NewInt(accBalance), hexAddrs); err != nil {
		return fmt.Errorf("failed to distribute ERC20: %v", err)
	}
	time.Sleep(time.Second * 5)

	// 5. Register the ERC20 as a gasless transfer token (owner-only), enabling gasless.
	if err := registerGaslessTransferToken(cli, ownerKey, erc20Addr); err != nil {
		return fmt.Errorf("failed to register gasless transfer token: %v", err)
	}

	log.Printf("✅ Gasless init done. ERC20=%s registered as a gasless transfer token; run: adventure gasless-bench -f <cfg> --contract %s\n",
		erc20Addr, erc20Addr)
	return nil
}

// GaslessBench runs a zero-gas-price ERC20 transfer benchmark against `contractAddr`, which must
// have been registered as a gasless transfer token (via gasless-init); otherwise the node rejects
// the zero-priced txs as underpriced.
func GaslessBench(configPath, contractAddr string) error {
	if configPath == "" {
		return errors.New("configPath must not be empty")
	}
	if err := loadConfig(configPath); err != nil {
		return err
	}

	to := ethcmn.HexToAddress(contractAddr)
	// gasPrice == 0 makes each tx zero-priced (gasless). The whitelist must already approve this
	// ERC20's transfer, or the mempool rejects it as underpriced.
	eParam := utils.NewTxParam(
		&to,
		nil,
		GaslessBenchTxGasLimit,
		big.NewInt(0),
		generateTxData(),
	)

	utils.RunTxs(
		func(_ ethcmn.Address) []utils.TxParam {
			return []utils.TxParam{eParam}
		},
	)

	return nil
}

// registerGaslessTransferToken enables gasless globally and whitelists `erc20`'s transfer, sending
// both owner-only txs from `ownerKey` (the whitelist owner seeded in genesis).
func registerGaslessTransferToken(cli utils.Client, ownerKey *ecdsa.PrivateKey, erc20 ethcmn.Address) error {
	wlABI, err := abi.JSON(strings.NewReader(GaslessWhitelistABI))
	if err != nil {
		return fmt.Errorf("failed to initialize GaslessWhitelist ABI: %v", err)
	}
	wl := ethcmn.HexToAddress(GaslessWhitelistAddr)
	owner := utils.GetEthAddressFromPK(ownerKey)
	gasPrice := utils.ParseGasPriceToBigInt(utils.TransferCfg.GasPriceGwei, 9)

	nonce, err := cli.QueryNonce(owner.String())
	if err != nil {
		return fmt.Errorf("failed to query owner nonce: %v", err)
	}

	enableData, err := wlABI.Pack("setGaslessEnabled", true)
	if err != nil {
		return err
	}
	h1, err := cli.SendEthereumTx(ownerKey, nonce, wl, nil, 200000, gasPrice, enableData)
	if err != nil {
		return fmt.Errorf("setGaslessEnabled: %v", err)
	}
	log.Printf("setGaslessEnabled(true): owner=%s, nonce=%d, txhash=%s\n", owner, nonce, h1)

	regData, err := wlABI.Pack("setGaslessTransferToken", erc20, true, GaslessTransferGasLimit)
	if err != nil {
		return err
	}
	h2, err := cli.SendEthereumTx(ownerKey, nonce+1, wl, nil, 200000, gasPrice, regData)
	if err != nil {
		return fmt.Errorf("setGaslessTransferToken: %v", err)
	}
	log.Printf("setGaslessTransferToken(%s, true, %d): owner=%s, nonce=%d, txhash=%s\n",
		erc20, GaslessTransferGasLimit, owner, nonce+1, h2)

	time.Sleep(time.Second * 5)
	return nil
}

// loadAccountAddresses reads the accounts file (addresses or private keys) into addresses, mirroring
// the loader in Erc20Init/NativeInit.
func loadAccountAddresses(accountsFile string) []ethcmn.Address {
	addresses := utils.ReadDataFromFile(accountsFile)
	if len(addresses) == 0 {
		return nil
	}
	hexAddrs := make([]ethcmn.Address, len(addresses))
	if !strings.HasPrefix(addresses[0], "0x") {
		for i, addr := range addresses {
			privKey, err := crypto.HexToECDSA(strings.TrimPrefix(addr, "0x"))
			if err != nil {
				log.Printf("Failed to convert private key string %s: %v\n", addr, err)
				break
			}
			hexAddrs[i] = utils.GetEthAddressFromPK(privKey)
		}
	} else {
		for i, addr := range addresses {
			hexAddrs[i] = ethcmn.HexToAddress(addr)
		}
	}
	return hexAddrs
}
