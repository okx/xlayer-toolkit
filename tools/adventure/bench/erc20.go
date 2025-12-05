package bench

import (
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"errors"
	"fmt"
	"io/ioutil"
	"log"
	"math/big"
	"os"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	ethcmn "github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/okx/adventure/utils"
)

var TotalSupplyAmount = big.NewInt(100000000)

// Contract deployment gas limits
const (
	GasLimitBatchTransferNative = 300000
	GasLimitERC20               = 10000000
	GasLimitBatchTransferERC20  = 500000
	BatchSize                   = 50
)

// ========================================
// ERC20 Initialization Functions
// ========================================

// Erc20Init deploys ERC20 and BatchTransfer contracts, and distributes tokens
func Erc20Init(amountStr, configPath string) error {
	// Load configuration
	if err := loadConfig(configPath); err != nil {
		return err
	}

	rpcURL := utils.TransferCfg.Rpc[0]
	accountsFile := utils.TransferCfg.AccountsFilePath

	if utils.TransferCfg.SenderPrivateKey == "" {
		return errors.New("senderPrivateKey must be set in config file")
	}

	// Parse private key
	pkHex := strings.TrimPrefix(utils.TransferCfg.SenderPrivateKey, "0x")
	privateKey, err := crypto.HexToECDSA(pkHex)
	if err != nil {
		log.Printf("Failed to parse private key: %v\n", err)
		os.Exit(1)
	}

	// Load addresses
	addresses := utils.ReadDataFromFile(accountsFile)
	hexAddrs := make([]ethcmn.Address, len(addresses))
	if !strings.HasPrefix(addresses[0], "0x") {
		// Support private key file input
		for i, addr := range addresses {
			addrHex := strings.TrimPrefix(addr, "0x")
			privKey, err := crypto.HexToECDSA(addrHex)
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

	cli := utils.NewClient(rpcURL)

	// 1. Deploy BatchTransfer for Native Token
	nonce, err := cli.QueryNonce(utils.GetEthAddressFromPK(privateKey).String())
	if err != nil {
		log.Printf("Failed to query nonce: %v\n", err)
		os.Exit(1)
	}

	nativeAddr, err := deployBTNative(cli, privateKey, nonce)
	if err != nil {
		log.Printf("Failed to deploy BatchTransfer for Native Token: %v\n", err)
		os.Exit(1)
	}
	time.Sleep(time.Second * 5)

	// Parse amount
	amount, err := parseAmountWithETH(amountStr)
	if err != nil {
		log.Printf("Failed to parse amount: %v\n", err)
		os.Exit(1)
	}

	// 2. Transfer Native Token
	if err := transfersNative(cli, privateKey, nonce+1, nativeAddr, amount, hexAddrs); err != nil {
		log.Printf("Failed to transfer Native Token: %v\n", err)
		os.Exit(1)
	}

	// 3. Deploy BatchTransfer for ERC20
	nonce, err = cli.QueryNonce(utils.GetEthAddressFromPK(privateKey).String())
	if err != nil {
		log.Printf("Failed to query nonce: %v\n", err)
		os.Exit(1)
	}

	bterc20Addr, err := deployBTERC20(cli, privateKey, nonce)
	if err != nil {
		log.Printf("Failed to deploy BatchTransfer for ERC20: %v\n", err)
		os.Exit(1)
	}
	time.Sleep(time.Second * 5)

	// 4. Deploy ERC20
	nonce, err = cli.QueryNonce(utils.GetEthAddressFromPK(privateKey).String())
	if err != nil {
		log.Printf("Failed to query nonce: %v\n", err)
		os.Exit(1)
	}

	erc20Addr, err := deployERC20(cli, privateKey, nonce)
	if err != nil {
		log.Printf("Failed to deploy ERC20: %v\n", err)
		os.Exit(1)
	}
	time.Sleep(time.Second * 5)

	// 5. Approve ERC20
	nonce, err = cli.QueryNonce(utils.GetEthAddressFromPK(privateKey).String())
	if err != nil {
		log.Printf("Failed to query nonce: %v\n", err)
		os.Exit(1)
	}

	err = sendApprove(cli, privateKey, nonce, erc20Addr, TotalSupplyAmount, bterc20Addr)
	if err != nil {
		log.Printf("Failed to approve ERC20: %v\n", err)
		os.Exit(1)
	}
	time.Sleep(time.Second * 5)

	// 6. Transfer ERC20
	nonce, err = cli.QueryNonce(utils.GetEthAddressFromPK(privateKey).String())
	if err != nil {
		log.Printf("Failed to query nonce: %v\n", err)
		os.Exit(1)
	}

	accBalance := TotalSupplyAmount.Int64() / int64(len(hexAddrs))
	if err := transferERC20(cli, privateKey, nonce, bterc20Addr, erc20Addr, big.NewInt(accBalance), hexAddrs); err != nil {
		log.Printf("Failed to transfer ERC20: %v\n", err)
		os.Exit(1)
	}

	log.Printf("✅ Finish! ERC20 Address: %s\n", erc20Addr)
	return nil
}

// ========================================
// ERC20 Benchmark Functions
// ========================================

// Erc20Bench runs ERC20 transfer benchmark
func Erc20Bench(configPath, contractAddr string) error {
	if configPath == "" {
		return errors.New("configPath must not be empty")
	}

	if err := loadConfig(configPath); err != nil {
		return err
	}

	gasPrice := utils.ParseGasPriceToBigInt(utils.TransferCfg.GasPriceGwei, 9)

	eParam := utils.NewTxParam(
		ethcmn.HexToAddress(contractAddr),
		nil,
		uint64(100000),
		gasPrice,
		generateTxData(),
	)

	utils.RunTxs(
		func(_ ethcmn.Address) []utils.TxParam {
			return []utils.TxParam{eParam}
		},
	)

	return nil
}

// ========================================
// Helper Functions
// ========================================

func parseAmountWithETH(amountStr string) (*big.Int, error) {
	amountStr = strings.TrimSpace(amountStr)

	if !strings.HasSuffix(strings.ToUpper(amountStr), "ETH") {
		return nil, fmt.Errorf("amount must end with 'ETH' suffix (e.g., '1ETH', '0.01ETH')")
	}

	ethValue := strings.TrimSuffix(strings.ToUpper(amountStr), "ETH")
	ethValue = strings.TrimSpace(ethValue)

	var ethFloat big.Float
	_, ok := ethFloat.SetString(ethValue)
	if !ok {
		return nil, fmt.Errorf("invalid numeric value: %s", ethValue)
	}

	weiPerEth := new(big.Float).SetInt(big.NewInt(1000000000000000000))
	weiFloat := new(big.Float).Mul(&ethFloat, weiPerEth)

	wei, _ := weiFloat.Int(nil)

	if wei.Cmp(big.NewInt(0)) <= 0 {
		return nil, fmt.Errorf("amount must be greater than 0")
	}

	return wei, nil
}

func generateTxData() []byte {
	erc20ABI, err := abi.JSON(strings.NewReader(ERC20ABI))
	if err != nil {
		panic(err)
	}
	txdata, err := erc20ABI.Pack("transfer", ethcmn.HexToAddress("0x2ECF31eCe36ccaC2d3222A303b1409233ECBB225"), new(big.Int).SetInt64(1))
	if err != nil {
		panic(err)
	}
	return txdata
}

// deployContract is a unified contract deployment function
func deployContract(
	cli utils.Client,
	privateKey *ecdsa.PrivateKey,
	nonce uint64,
	contractName string,
	gasLimit uint64,
	bytecode string,
) (ethcmn.Address, error) {
	gasPrice := utils.ParseGasPriceToBigInt(utils.TransferCfg.GasPriceGwei, 9)
	txhash, err := cli.CreateContract(privateKey, nonce, nil, gasLimit, gasPrice, ethcmn.Hex2Bytes(bytecode))
	if err != nil {
		return ethcmn.Address{}, err
	}
	contractAddr := crypto.CreateAddress(utils.GetEthAddressFromPK(privateKey), nonce)
	log.Printf("%s: caller=%s, nonce=%d, contract=%s, txhash=%s\n",
		contractName, utils.GetEthAddressFromPK(privateKey), nonce, contractAddr, txhash)

	// Wait for contract deployment to be mined
	for i := 0; i < 30; i++ {
		time.Sleep(time.Second)
		code, err := cli.CodeAt(context.Background(), contractAddr, nil)
		if err == nil && len(code) > 0 {
			return contractAddr, nil
		}
	}

	return ethcmn.Address{}, fmt.Errorf("contract deployment timeout: %s", contractAddr.Hex())
}

func loadConfig(configPath string) error {
	file, err := os.Open(configPath)
	if err != nil {
		return err
	}
	defer file.Close()

	data, err := ioutil.ReadAll(file)
	if err != nil {
		return err
	}

	if err := json.Unmarshal(data, &utils.TransferCfg); err != nil {
		return err
	}

	privateKeys := utils.ReadDataFromFile(utils.TransferCfg.AccountsFilePath)
	utils.TransferCfg.BenchmarkAccounts = privateKeys

	return nil
}

func deployBTNative(cli utils.Client, privateKey *ecdsa.PrivateKey, nonce uint64) (ethcmn.Address, error) {
	return deployContract(cli, privateKey, nonce, "BatchTransfer Native", GasLimitBatchTransferNative, BatchTransferNativeHex)
}

func deployERC20(cli utils.Client, privateKey *ecdsa.PrivateKey, nonce uint64) (ethcmn.Address, error) {
	return deployContract(cli, privateKey, nonce, "ERC20 Contract", GasLimitERC20, ERC20Hex)
}

func deployBTERC20(cli utils.Client, privateKey *ecdsa.PrivateKey, nonce uint64) (ethcmn.Address, error) {
	return deployContract(cli, privateKey, nonce, "BatchTransfer ERC20", GasLimitBatchTransferERC20, BatchTransferHex)
}

func sendApprove(cli utils.Client, privateKey *ecdsa.PrivateKey, nonce uint64, to ethcmn.Address, totalSupply *big.Int, bterc20Addrs ethcmn.Address) error {
	gasPrice := utils.ParseGasPriceToBigInt(utils.TransferCfg.GasPriceGwei, 9)

	tABI, err := abi.JSON(strings.NewReader(ERC20ABI))
	if err != nil {
		return fmt.Errorf("failed to initialize ERC20 ABI: %s", err)
	}
	txdata, err := tABI.Pack("approve", bterc20Addrs, totalSupply)
	if err != nil {
		return err
	}
	txhash, err := cli.SendEthereumTx(privateKey, nonce, to, nil, uint64(3000000), gasPrice, txdata)
	if err != nil {
		return err
	}
	log.Printf("Approve to BatchTransfer: caller=%s, nonce=%d, txhash=%s\n",
		utils.GetEthAddressFromPK(privateKey), nonce, txhash)
	return nil
}

func transfersNative(cli utils.Client, privateKey *ecdsa.PrivateKey, nonce uint64, to ethcmn.Address, amount *big.Int, addrs []ethcmn.Address) error {
	tABI, err := abi.JSON(strings.NewReader(BatchTransferNativeABI))
	if err != nil {
		return fmt.Errorf("failed to initialize BatchTransfer ABI: %s", err)
	}

	totalAmount := big.NewInt(1).Mul(amount, big.NewInt(int64(BatchSize)))

	gasPrice := utils.ParseGasPriceToBigInt(utils.TransferCfg.GasPriceGwei, 9)

	for i := 0; i <= len(addrs)/BatchSize && i*BatchSize < len(addrs); i++ {
		start, end := i*BatchSize, (i+1)*BatchSize
		if end > len(addrs) {
			end = len(addrs)
		}
		txdata, err := tABI.Pack("transfers", addrs[start:end], amount)
		if err != nil {
			return fmt.Errorf("failed to pack BatchTransfer parameters: %s", err)
		}
		if end-start < BatchSize {
			totalAmount = big.NewInt(1).Mul(amount, big.NewInt(int64(end-start)))
		}
		txhash, err := cli.SendEthereumTx(privateKey, nonce, to, totalAmount, uint64(41000*BatchSize), gasPrice, txdata)
		if err != nil {
			return err
		}
		log.Printf("[BatchTransfer Native] caller=%s, nonce=%d, to[%d:%d], txhash=%s\n",
			utils.GetEthAddressFromPK(privateKey), nonce, start, end-1, txhash)

		nonce++
	}

	return nil
}

func transferERC20(cli utils.Client, privateKey *ecdsa.PrivateKey, nonce uint64, bterc20Addr, tokenAddr ethcmn.Address, amount *big.Int, addrs []ethcmn.Address) error {
	tABI, err := abi.JSON(strings.NewReader(BatchTransferABI))
	if err != nil {
		return fmt.Errorf("failed to initialize BatchTransferERC20 ABI: %s", err)
	}

	gasPrice := utils.ParseGasPriceToBigInt(utils.TransferCfg.GasPriceGwei, 9)

	for i := 0; i <= len(addrs)/BatchSize && i*BatchSize < len(addrs); i++ {
		start, end := i*BatchSize, (i+1)*BatchSize
		if end > len(addrs) {
			end = len(addrs)
		}
		txdata, err := tABI.Pack("batchTransferERC20", addrs[start:end], tokenAddr, amount)
		if err != nil {
			return fmt.Errorf("failed to pack BatchTransferERC20 parameters: %s", err)
		}
		txhash, err := cli.SendEthereumTx(privateKey, nonce, bterc20Addr, nil, uint64(100000*BatchSize), gasPrice, txdata)
		if err != nil {
			return err
		}
		log.Printf("[BatchTransfer ERC20] caller=%s, nonce=%d, to[%d:%d], txhash=%s\n",
			utils.GetEthAddressFromPK(privateKey), nonce, start, end-1, txhash)

		nonce++
	}

	return nil
}
