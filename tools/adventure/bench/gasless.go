package bench

import (
	"context"
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

// Gasless whitelist addresses, keyed by chain id. These MUST match the address op-reth's gasless hook
// actually reads, or registering a token here has no effect and zero-priced txs are rejected as
// underpriced.
//   - 195 (local devnet): the GaslessWhitelist proxy deployed by devnet/scripts/deploy-gasless.sh,
//     equal to alloy-op-evm's XLAYER_DEVNET_GASLESS_CONTRACT.
//   - 1952 / 196 (XLayer testnet / mainnet): the deployed GaslessWhitelist contract.
const (
	GaslessWhitelistAddrDevnet = "0xA9092BC02e2000a3F8996D1991621E9A03Ef2dfE" // chain id 195
	GaslessWhitelistAddrXLayer = "0x19787404b0c70021b4752028f7e3a92313885B27" // chain id 1952 / 196
)

// GaslessDevnetChainID is the local devnet chain id. Only on this chain does adventure own the
// whitelist owner key, so registering the deployed ERC20 as a gasless transfer token (and using the
// hardcoded owner key below) is gated on it. On 1952 / 196 the tokens must already be whitelisted.
const GaslessDevnetChainID int64 = 195

// GaslessDevnetOwnerPrivateKey is the genesis-seeded gasless whitelist owner on the local devnet
// (chain id 195). It is a well-known devnet key, not a secret, and is only ever used against 195.
const GaslessDevnetOwnerPrivateKey = "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356"

// DefaultApproveSpender is the fallback spender for the gasless `approve` scenario when the config
// leaves approveSpender empty (any address works — approve only records an allowance).
const DefaultApproveSpender = "0x203B9aD06aeb929427E233587F0020661dd23B11"

// GaslessTransferRecipient is the (arbitrary) recipient for the gasless `transfer` scenario. The
// whitelist only checks the token address and selector, not the recipient.
const GaslessTransferRecipient = "0x000000000000000000000000000000000000dEaD"

// GaslessTransferGasLimit is the per-tx gas allowance registered for the ERC20 transfer rule.
const GaslessTransferGasLimit uint64 = 1000000

// gaslessWhitelistAddr returns the gasless whitelist predeploy address for the given chain id.
func gaslessWhitelistAddr(chainID int64) string {
	if chainID == GaslessDevnetChainID {
		return GaslessWhitelistAddrDevnet
	}
	return GaslessWhitelistAddrXLayer
}

// GaslessBenchTxGasLimit is the gas limit set on each benchmark gasless transfer.
const GaslessBenchTxGasLimit uint64 = 100000

// GaslessWhitelistABI is the subset of contracts-bedrock src/L2/XlayerGaslessWhitelist.sol needed to
// enable gasless and register an ERC20 as a gasless transfer token.
const GaslessWhitelistABI = `[
	{"inputs":[{"internalType":"bool","name":"enabled","type":"bool"}],"name":"setGaslessEnabled","outputs":[],"stateMutability":"nonpayable","type":"function"},
	{"inputs":[{"internalType":"address","name":"token","type":"address"},{"internalType":"bool","name":"allowed","type":"bool"},{"internalType":"uint64","name":"gasLimit","type":"uint64"}],"name":"setGaslessTransferToken","outputs":[],"stateMutability":"nonpayable","type":"function"},
	{"inputs":[{"internalType":"address","name":"token","type":"address"},{"internalType":"address","name":"spender","type":"address"},{"internalType":"bool","name":"allowed","type":"bool"},{"internalType":"uint64","name":"gasLimit","type":"uint64"}],"name":"setApproveSpender","outputs":[],"stateMutability":"nonpayable","type":"function"}
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

	rpcURL := utils.TransferCfg.Rpc[0]
	accountsFile, err := GetConfigFilePath(utils.TransferCfg.Accounts)
	if err != nil {
		return fmt.Errorf("failed to get accounts file path: %v", err)
	}

	senderKey, err := crypto.HexToECDSA(strings.TrimPrefix(utils.TransferCfg.SenderPrivateKey, "0x"))
	if err != nil {
		return fmt.Errorf("failed to parse senderPrivateKey: %v", err)
	}

	hexAddrs := loadAccountAddresses(accountsFile)
	if len(hexAddrs) == 0 {
		return errors.New("no benchmark accounts loaded")
	}

	cli := utils.NewClient(rpcURL)
	chainID, err := cli.ChainID(context.Background())
	if err != nil {
		return fmt.Errorf("failed to query chainId: %v", err)
	}
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

	// 5. Register the ERC20 as a gasless transfer token (owner-only), enabling gasless. Only the local
	// devnet (chain id 195) ships the whitelist owner key, so registration is gated on it; on
	// 1952 / 196 the benchmark token must already be whitelisted on-chain.
	if chainID.Int64() == GaslessDevnetChainID {
		ownerKey, err := crypto.HexToECDSA(strings.TrimPrefix(GaslessDevnetOwnerPrivateKey, "0x"))
		if err != nil {
			return fmt.Errorf("failed to parse devnet gasless owner key: %v", err)
		}
		// approveSpender must match the spender the `approve` bench scenario uses, or the approve
		// rule won't match (the whitelist keys approve rules by the (token, spender) pair).
		approveSpender := utils.TransferCfg.ApproveSpender
		if approveSpender == "" {
			approveSpender = DefaultApproveSpender
		}
		if err := registerGaslessTransferToken(cli, ownerKey, erc20Addr, ethcmn.HexToAddress(approveSpender), chainID.Int64()); err != nil {
			return fmt.Errorf("failed to register gasless transfer token: %v", err)
		}
		log.Printf("✅ Gasless init done. ERC20=%s registered (transfer + approve spender=%s gasless); run: adventure gasless-bench -f <cfg> --contract %s\n",
			erc20Addr, approveSpender, erc20Addr)
	} else {
		log.Printf("✅ Gasless init done. ERC20=%s deployed and distributed (chain id %d: registration skipped — token must already be whitelisted on-chain)\n",
			erc20Addr, chainID.Int64())
	}
	return nil
}

// GaslessBench runs a zero-gas-price ERC20 benchmark for the given scenario. Mirroring
// scripts/gasless/test.js, two scenarios are supported, both as legacy (type 0) gasPrice=0 txs:
//   - "approve":  approve(approveSpender, 0) on tokenApprove
//   - "transfer": transfer(deadAddr, 0)      on tokenTransfer
//
// The token must already be a gasless-whitelisted token, or the node rejects the zero-priced txs as
// underpriced. Token addresses come from the config file (tokenApprove / tokenTransfer); if
// `contractAddr` is non-empty (the devnet path, set by the Makefile to gasless-init's freshly
// deployed ERC20) it overrides both. approveSpender comes from the config, defaulting to
// DefaultApproveSpender.
func GaslessBench(configPath, contractAddr, scenario string) error {
	if configPath == "" {
		return errors.New("configPath must not be empty")
	}
	if err := loadConfig(configPath); err != nil {
		return err
	}

	tokenApprove := utils.TransferCfg.TokenApprove
	tokenTransfer := utils.TransferCfg.TokenTransfer
	if contractAddr != "" {
		tokenApprove = contractAddr
		tokenTransfer = contractAddr
	}
	approveSpender := utils.TransferCfg.ApproveSpender
	if approveSpender == "" {
		approveSpender = DefaultApproveSpender
	}

	to, data, err := buildGaslessTxData(scenario, tokenApprove, approveSpender, tokenTransfer)
	if err != nil {
		return err
	}
	log.Printf("gasless-bench scenario=%s to=%s spender=%s\n", scenario, to.Hex(), approveSpender)

	// gasPrice == 0 makes each tx zero-priced (gasless). The whitelist must already approve this
	// token's selector, or the mempool rejects it as underpriced.
	eParam := utils.NewTxParam(
		&to,
		nil,
		GaslessBenchTxGasLimit,
		big.NewInt(0),
		data,
	)

	utils.RunTxs(
		func(_ ethcmn.Address) []utils.TxParam {
			return []utils.TxParam{eParam}
		},
	)

	return nil
}

// buildGaslessTxData returns the target token and calldata for a gasless scenario. Amounts are 0 so
// the txs never revert on balance/allowance and the bench can run indefinitely.
func buildGaslessTxData(scenario, tokenApprove, approveSpender, tokenTransfer string) (ethcmn.Address, []byte, error) {
	erc20ABI, err := abi.JSON(strings.NewReader(ERC20ABI))
	if err != nil {
		return ethcmn.Address{}, nil, fmt.Errorf("failed to initialize ERC20 ABI: %v", err)
	}

	switch scenario {
	case "approve":
		if tokenApprove == "" {
			return ethcmn.Address{}, nil, errors.New("tokenApprove must be set (config tokenApprove or --contract)")
		}
		data, err := erc20ABI.Pack("approve", ethcmn.HexToAddress(approveSpender), big.NewInt(0))
		if err != nil {
			return ethcmn.Address{}, nil, err
		}
		return ethcmn.HexToAddress(tokenApprove), data, nil
	case "transfer":
		if tokenTransfer == "" {
			return ethcmn.Address{}, nil, errors.New("tokenTransfer must be set (config tokenTransfer or --contract)")
		}
		data, err := erc20ABI.Pack("transfer", ethcmn.HexToAddress(GaslessTransferRecipient), big.NewInt(0))
		if err != nil {
			return ethcmn.Address{}, nil, err
		}
		return ethcmn.HexToAddress(tokenTransfer), data, nil
	default:
		return ethcmn.Address{}, nil, fmt.Errorf("unknown gasless scenario %q (use: approve | transfer)", scenario)
	}
}

// registerGaslessTransferToken enables gasless globally and whitelists `erc20` for both the
// `transfer(address,uint256)` selector and `approve(spender,uint256)` for `approveSpender` (the
// whitelist keys approve rules by the (token, spender) pair), sending the owner-only txs from
// `ownerKey` (the whitelist owner seeded in genesis).
func registerGaslessTransferToken(cli utils.Client, ownerKey *ecdsa.PrivateKey, erc20, approveSpender ethcmn.Address, chainID int64) error {
	wlABI, err := abi.JSON(strings.NewReader(GaslessWhitelistABI))
	if err != nil {
		return fmt.Errorf("failed to initialize GaslessWhitelist ABI: %v", err)
	}
	wl := ethcmn.HexToAddress(gaslessWhitelistAddr(chainID))
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

	approveData, err := wlABI.Pack("setApproveSpender", erc20, approveSpender, true, GaslessTransferGasLimit)
	if err != nil {
		return err
	}
	h3, err := cli.SendEthereumTx(ownerKey, nonce+2, wl, nil, 200000, gasPrice, approveData)
	if err != nil {
		return fmt.Errorf("setApproveSpender: %v", err)
	}
	log.Printf("setApproveSpender(%s, %s, true, %d): owner=%s, nonce=%d, txhash=%s\n",
		erc20, approveSpender, GaslessTransferGasLimit, owner, nonce+2, h3)

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
