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

	// Gasless benchmark targets (see bench/gasless.go). Mirror the TOKEN_APPROVE / APPROVE_SPENDER /
	// TOKEN_TRANSFER env vars in scripts/gasless/test.js. For the local devnet (chain id 195) these
	// are overridden by gasless-init's freshly deployed ERC20 (via the Makefile --contract flag); for
	// other chains (1952 / 196) set them to already-whitelisted tokens here.
	TokenApprove   string `json:"tokenApprove"`   // ERC20 whose approve(...) is gasless
	ApproveSpender string `json:"approveSpender"` // spender passed to approve(spender, amount)
	TokenTransfer  string `json:"tokenTransfer"`  // ERC20 whose transfer(...) is gasless

	BenchmarkAccounts []string // benchmark accounts for stress testing (both senders and receivers)
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
