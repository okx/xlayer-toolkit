package bench

import (
	"crypto/ecdsa"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math"
	"math/big"
	"os"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	ethcmn "github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/okx/adventure/utils"
)

type SimulatorArtifacts struct {
	Simulator string `json:"simulator"`
}

// SimulatorInit

func SimulatorInit(amountStr string, configPath string) error {
	// Load configuration
	if err := loadConfig(configPath); err != nil {
		return err
	}

	rpcURL := utils.TransferCfg.Rpc[0]
	cli := utils.NewClient(rpcURL)

	// Parse private key
	pkHex := strings.TrimPrefix(utils.TransferCfg.SenderPrivateKey, "0x")
	privateKey, err := crypto.HexToECDSA(pkHex)
	if err != nil {
		log.Printf("Failed to parse private key: %v\n", err)
		os.Exit(1)
	}

	accountsFile, err := GetConfigFilePath(utils.TransferCfg.Accounts)
	if err != nil {
		return fmt.Errorf("failed to get accounts file path: %v", err)
	}

	if utils.TransferCfg.SenderPrivateKey == "" {
		return errors.New("senderPrivateKey must be set in config file")
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

	// 1. Deploy BatchTransfer for Native Token
	nonce, err = cli.QueryNonce(utils.GetEthAddressFromPK(privateKey).String())
	if err != nil {
		log.Printf("Failed to query nonce: %v\n", err)
		os.Exit(1)
	}

	simulatorAddr, err := deploySimulator(cli, privateKey, nonce)
	if err != nil {
		log.Printf("Failed to deploy Simulator: %v\n", err)
		os.Exit(1)
	}

	log.Printf("✅ Finish! io bench simulator Address: %s\n", simulatorAddr)
	// write address to file testdata/aritfacts/simulator.json with json structure {"simulator": "0x..."}
	if err := utils.WriteJSONToFile(map[string]string{"simulator": simulatorAddr}, simulatorArtifacts); err != nil {
		log.Printf("Failed to write address to file: %v\n", err)
		os.Exit(1)
	}

	return nil
}

func deploySimulator(cli utils.Client, privateKey *ecdsa.PrivateKey, nonce uint64) (string, error) {

	hexBin, err := hex.DecodeString(SimulatorByteCodeBinHex)
	if err != nil {
		return "", err
	}
	simABI, err := abi.JSON(strings.NewReader(SimulatorABI))
	if err != nil {
		return "", err
	}
	// Pack constructor arguments (if any)
	constructorData, err := simABI.Pack("", big.NewInt(math.MaxInt64))
	if err != nil {
		return "", err
	}
	// Create contract creation transaction
	address, err := deployContract(cli, privateKey, nonce, "Simulator", 8000000, hex.EncodeToString(append(hexBin, constructorData...)))
	if err != nil {
		return "", err
	}

	const OneEther = 1e18
	const tenGwei = 10e9
	nonce, err = cli.QueryNonce(utils.GetEthAddressFromPK(privateKey).String())
	if err != nil {
		return "", err
	}
	txHash, err := cli.SendEthereumTx(privateKey, nonce, address, big.NewInt(OneEther), 8000000, big.NewInt(tenGwei), nil)
	if err != nil {
		return "", err
	}
	time.Sleep(3 * time.Second)
	log.Printf("Funded simulator contract with 1 ETH, tx hash: %s\n", txHash.Hex())
	log.Printf("Deploying simulator contract, address: %s\n", address.String())
	return address.String(), nil
}

func IOBench(configPath string) error {
	// Load configuration
	if err := loadConfig(configPath); err != nil {
		return err
	}
	bs, err := os.ReadFile(simulatorArtifacts)
	if err != nil {
		log.Printf("Failed to read simulator artifacts: %v\n", err)
		os.Exit(1)
	}
	var artifacts SimulatorArtifacts
	if err := json.Unmarshal(bs, &artifacts); err != nil {
		log.Printf("Failed to unmarshal simulator artifacts: %v\n", err)
		os.Exit(1)
	}
	gasPrice := utils.ParseGasPriceToBigInt(utils.TransferCfg.GasPriceGwei, 9)

	to := ethcmn.HexToAddress(artifacts.Simulator)
	eParam := utils.NewTxParam(
		&to,
		nil,
		uint64(3000000),
		gasPrice,
		generateIOBenchTxData(),
	)

	utils.RunTxs(
		func(_ ethcmn.Address) []utils.TxParam {
			return []utils.TxParam{eParam}
		},
	)

	return nil
}

func FibBench(configPath string) error {
	// Load configuration
	if err := loadConfig(configPath); err != nil {
		return err
	}
	bs, err := os.ReadFile(simulatorArtifacts)
	if err != nil {
		log.Printf("Failed to read simulator artifacts: %v\n", err)
		os.Exit(1)
	}
	var artifacts SimulatorArtifacts
	if err := json.Unmarshal(bs, &artifacts); err != nil {
		log.Printf("Failed to unmarshal simulator artifacts: %v\n", err)
		os.Exit(1)
	}
	gasPrice := utils.ParseGasPriceToBigInt(utils.TransferCfg.GasPriceGwei, 9)

	to := ethcmn.HexToAddress(artifacts.Simulator)
	eParam := utils.NewTxParam(
		&to,
		nil,
		uint64(300000),
		gasPrice,
		generateFibBenchTxData(),
	)

	utils.RunTxs(
		func(_ ethcmn.Address) []utils.TxParam {
			return []utils.TxParam{eParam}
		},
	)

	return nil
}

type PrecompileConfig struct {
	PrecompileAddress ethcmn.Address
	NumCalls          *big.Int
}

type SimulatorConfig struct {
	LoadAccounts   *big.Int
	UpdateAccounts *big.Int
	CreateAccounts *big.Int
	LoadStorage    *big.Int
	UpdateStorage  *big.Int
	DeleteStorage  *big.Int
	CreateStorage  *big.Int
	Precompiles    []PrecompileConfig
}

func generateIOBenchTxData() []byte {
	simulatorABI, err := abi.JSON(strings.NewReader(SimulatorABI))
	if err != nil {
		panic(err)
	}
	fmt.Printf("SimulatorParams: %#v\n", utils.TransferCfg.SimulatorParams.SimulatorConfig)
	config := SimulatorConfig{
		LoadAccounts:   big.NewInt(utils.TransferCfg.SimulatorParams.SimulatorConfig.LoadAccounts),
		UpdateAccounts: big.NewInt(utils.TransferCfg.SimulatorParams.SimulatorConfig.UpdateAccounts),
		CreateAccounts: big.NewInt(utils.TransferCfg.SimulatorParams.SimulatorConfig.CreateAccounts),
		LoadStorage:    big.NewInt(utils.TransferCfg.SimulatorParams.SimulatorConfig.LoadStorage),
		UpdateStorage:  big.NewInt(utils.TransferCfg.SimulatorParams.SimulatorConfig.UpdateStorage),
		DeleteStorage:  big.NewInt(utils.TransferCfg.SimulatorParams.SimulatorConfig.DeleteStorage),
		CreateStorage:  big.NewInt(utils.TransferCfg.SimulatorParams.SimulatorConfig.CreateStorage),
	}

	// Encode calldata for run((...))
	txdata, err := simulatorABI.Pack("run", config)
	if err != nil {
		panic(err)
	}

	return txdata
}

func generateFibBenchTxData() []byte {
	simulatorABI, err := abi.JSON(strings.NewReader(SimulatorABI))
	if err != nil {
		panic(err)
	}

	// Encode calldata for run((...))
	txdata, err := simulatorABI.Pack("fib", big.NewInt(utils.TransferCfg.SimulatorParams.SimulatorConfig.Fib))
	if err != nil {
		panic(err)
	}

	return txdata
}
