package bench

import (
	"crypto/ecdsa"
	"encoding/json"
	"errors"
	"fmt"
	"io/ioutil"
	"log"
	"math/big"
	mathrand "math/rand"
	"os"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	ethcmn "github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/okx/adventure/utils"
)

// ========================================
// Native Token Batch Transfer Functions
// ========================================

// init initializes the random number generator seed for math/rand
func init() {
	mathrand.Seed(time.Now().UnixNano())
}

// NativeInit deploys BatchTransfer contract and distributes native tokens
func NativeInit(amountStr, configPath string) error {
	// Load configuration
	if err := loadNativeConfig(configPath); err != nil {
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

	// Query nonce
	nonce, err := cli.QueryNonce(utils.GetEthAddressFromPK(privateKey).String())
	if err != nil {
		log.Printf("Failed to query nonce: %v\n", err)
		os.Exit(1)
	}

	// 1. Deploy BatchTransfer contract
	contractAddr, err := deployNativeBT(cli, privateKey, nonce)
	if err != nil {
		log.Printf("Failed to deploy BatchTransfer: %v\n", err)
		os.Exit(1)
	}
	time.Sleep(time.Second * 5)

	// 2. Parse amount and transfer
	amount, err := parseNativeAmountWithETH(amountStr)
	if err != nil {
		log.Printf("Failed to parse amount: %v\n", err)
		os.Exit(1)
	}

	if err := transfersNativeBatch(cli, privateKey, nonce+1, contractAddr, amount, hexAddrs); err != nil {
		log.Printf("Failed to batch transfer: %v\n", err)
		os.Exit(1)
	}

	log.Printf("✅ Native token batch transfer completed!\n")
	return nil
}

// NativeBench runs native token transfer benchmark
func NativeBench(configPath string) error {
	amount := new(big.Int).SetUint64(1)

	if configPath == "" {
		return errors.New("configPath must not be empty")
	}

	if err := loadNativeConfig(configPath); err != nil {
		return err
	}

	gasPrice := utils.ParseGasPriceToBigInt(utils.TransferCfg.GasPriceGwei, 9)

	// Generate random recipient addresses to simulate real-world transfer scenarios
	toAddrs := generateAddresses()

	utils.RunTxs(
		func(addr ethcmn.Address) []utils.TxParam {
			to := toAddrs[mathrand.Intn(len(toAddrs))]
			return []utils.TxParam{utils.NewTxParam(to, amount, 21000, gasPrice, nil)}
		},
	)

	return nil
}

// ========================================
// Helper Functions
// ========================================

func parseNativeAmountWithETH(amountStr string) (*big.Int, error) {
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

func loadNativeConfig(configPath string) error {
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

func generateAddresses() []ethcmn.Address {
	privateKeys := utils.TransferCfg.BenchmarkAccounts

	leng := len(privateKeys)
	addrs := make([]ethcmn.Address, leng)
	for i := 0; i < leng; i++ {
		pk, err := crypto.HexToECDSA(privateKeys[i])
		if err != nil {
			panic(err)
		}
		addrs[i] = utils.GetEthAddressFromPK(pk)
	}
	return addrs
}

func deployNativeBT(cli utils.Client, privateKey *ecdsa.PrivateKey, nonce uint64) (ethcmn.Address, error) {
	gasPrice := utils.ParseGasPriceToBigInt(utils.TransferCfg.GasPriceGwei, 9)
	txhash, err := cli.CreateContract(privateKey, nonce, nil, 300000, gasPrice, ethcmn.Hex2Bytes(BatchTransferNativeHex))
	if err != nil {
		return ethcmn.Address{}, err
	}
	contractAddr := crypto.CreateAddress(utils.GetEthAddressFromPK(privateKey), nonce)
	log.Printf("BatchTransfer Native Deploy: caller=%s, nonce=%d, contract=%s, txhash=%s\n",
		utils.GetEthAddressFromPK(privateKey), nonce, contractAddr, txhash)
	return contractAddr, nil
}

func transfersNativeBatch(cli utils.Client, privateKey *ecdsa.PrivateKey, nonce uint64, to ethcmn.Address, amount *big.Int, addrs []ethcmn.Address) error {
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
		log.Printf("[Native Batch Transfer] caller=%s, nonce=%d, to[%d:%d], txhash=%s\n",
			utils.GetEthAddressFromPK(privateKey), nonce, start, end-1, txhash)

		nonce++
	}

	return nil
}
