package utils

var (
	TransferCfg TransferConfig
)

type TransferConfig struct {
	Rpc                   []string        `json:"rpc"`
	Accounts              int             `json:"accounts"`
	SenderPrivateKey      string          `json:"senderPrivateKey"`
	Concurrency           int             `json:"concurrency"`
	MempoolPauseThreshold int             `json:"mempoolPauseThreshold"`
	TargetTPS             int             `json:"targetTPS"`    // Target transactions per second, 0 means no limit
	MaxBatchSize          int             `json:"maxBatchSize"` // Maximum transactions per batch, default 100
	GasPriceGwei          float64         `json:"gasPriceGwei"`
	SaveTxHashes          bool            `json:"saveTxHashes"`
	SimulatorParams       SimulatorParams `json:"simulatorParams"`
	BenchmarkAccounts     []string        // 20k accounts for stress testing (both senders and receivers)
}

type SimulatorParams struct {
	SimulatorConfig SimulatorConfig `json:"simulatorConfig"`
}

type PrecompileConfig struct {
	PrecompileAddress string `json:"precompile_address"`
	NumCalls          uint64 `json:"num_calls"`
}

type SimulatorConfig struct {
	LoadAccounts   int64              `json:"load_accounts"`
	UpdateAccounts int64              `json:"update_accounts"`
	CreateAccounts int64              `json:"create_accounts"`
	LoadStorage    int64              `json:"load_storage"`
	UpdateStorage  int64              `json:"update_storage"`
	DeleteStorage  int64              `json:"delete_storage"`
	CreateStorage  int64              `json:"create_storage"`
	Fib            int64              `json:"fib"`
	Precompiles    []PrecompileConfig `json:"precompiles"`
}
