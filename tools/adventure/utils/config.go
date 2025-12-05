package utils

var (
	TransferCfg TransferConfig
)

type TransferConfig struct {
	Rpc                   []string `json:"rpc"`
	AccountsFilePath      string   `json:"accountsFilePath"`
	SenderPrivateKey      string   `json:"senderPrivateKey"`
	Concurrency           int      `json:"concurrency"`
	MempoolPauseThreshold int      `json:"mempoolPauseThreshold"`
	GasPriceGwei          float64  `json:"gasPriceGwei"`
	SaveTxHashes          bool     `json:"saveTxHashes"`
	BenchmarkAccounts     []string // 20k accounts for stress testing (both senders and receivers)
}
