package bench

import (
	"encoding/hex"
	"errors"

	ethcmn "github.com/ethereum/go-ethereum/common"
	"github.com/okx/adventure/utils"
)

func CreateBench(configPath string) error {
	if configPath == "" {
		return errors.New("configPath must not be empty")
	}

	if err := loadConfig(configPath); err != nil {
		return err
	}

	gasPrice := utils.ParseGasPriceToBigInt(utils.TransferCfg.GasPriceGwei, 9)

	eParam := utils.NewTxParam(
		nil,
		nil,
		GasLimitERC20,
		gasPrice,
		generateCreateTxData(),
	)

	utils.RunTxs(
		func(_ ethcmn.Address) []utils.TxParam {
			return []utils.TxParam{eParam}
		},
	)

	return nil
}

func generateCreateTxData() []byte {
	txData, err := hex.DecodeString(ERC20Hex)
	if err != nil {
		panic("failed to decode ERC20Hex: " + err.Error())
	}
	return txData
}
