package bench

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	cryptorand "crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"math/big"
	mathrand "math/rand"
	"strings"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	ethcmn "github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/rlp"
	"golang.org/x/time/rate"

	"github.com/okx/adventure/utils"
)

const (
	aaTxType    byte = 0x7b
	aaPayerType byte = 0x7c

	aaSigSecp = "secp"
	aaSigP256 = "p256"

	aaTxNative = "native"
	aaTxERC20  = "erc20"

	aaPayerSender = "sender"
	aaPayerRandom = "random"

	aaDefaultGasLimit       uint64 = 55000
	aaERC20GasLimitExtra    uint64 = 40000
	aaP256GasLimitExtra     uint64 = 80000
	aaRandomPayerGasExtra   uint64 = 30000
	aaP256InitGasLimit      uint64 = 500000
	aaMaxNonceLanes         uint64 = 4096
	aaBalanceCheckBatchSize        = 500
	aaNonceFreeExpiryOffset uint64 = 25
	aaConfigChangeType      uint8  = 0x01
	aaOwnerAuthorizeType    uint8  = 0x01
	aaOwnerScopeSender      uint8  = 0x02
	aaOwnerScopePayer       uint8  = 0x04
	aaOwnerScopeSenderPayer uint8  = aaOwnerScopeSender | aaOwnerScopePayer
)

var (
	aaK1Verifier       = ethcmn.HexToAddress("0x0000000000000000000000000000000000000001")
	aaP256RawVerifier  = ethcmn.HexToAddress("0x75E9779603e826f2D8d4dD7Edee3F0a737e4228d")
	aaAccountConfig    = ethcmn.HexToAddress("0xf946601D5424118A4e4054BB0B13133f216b4FeE")
	aaStorageSlotZero  = make([]byte, 32)
	aaStorageSlotOne   = uint256Bytes(big.NewInt(1))
	aaConfigTypehash   = crypto.Keccak256([]byte("SignedOwnerChanges(address account,uint64 chainId,uint64 sequence,OwnerChange[] ownerChanges)OwnerChange(uint8 changeType,address verifier,bytes32 ownerId,uint8 scope)"))
	aaP256HalfOrder, _ = new(big.Int).SetString("7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8", 16)
	aaU256Max          = new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 256), big.NewInt(1))
)

type aaNonceLane struct {
	id    string
	label string
	key   *big.Int
}

type aaNonceLaneSet struct {
	lanes   []aaNonceLane
	display string
}

type aaCallEntry struct {
	To   []byte
	Data []byte
}

type aaOwnerChangeRLP struct {
	ChangeType uint8
	Verifier   []byte
	OwnerID    []byte
	Scope      uint8
}

type aaTx struct {
	ChainID              uint64
	Sender               *ethcmn.Address
	NonceKey             *big.Int
	NonceSequence        uint64
	Expiry               uint64
	MaxPriorityFeePerGas *big.Int
	MaxFeePerGas         *big.Int
	GasLimit             uint64
	AccountChanges       []interface{}
	Calls                [][]aaCallEntry
	Payer                *ethcmn.Address
	SenderAuth           []byte
	PayerAuth            []byte
}

type aaBenchAccount struct {
	lock          sync.Mutex
	seq           uint64
	queried       bool
	seqByLane     map[string]uint64
	queriedByLane map[string]bool
	nextLane      uint64
	privateKey    *ecdsa.PrivateKey
	address       ethcmn.Address
	p256          *aaP256Key
}

type aaPendingTx struct {
	sender      *aaBenchAccount
	nonceLaneID string
	nonceFree   bool
}

type aaP256Key struct {
	privateKey *ecdsa.PrivateKey
	publicKey  []byte // x || y, 64 bytes
	ownerID    []byte // keccak256(publicKey)
}

// AAInit prepares accounts for AA benchmark modes that need on-chain owner config.
func AAInit(configPath, sigMode string) error {
	sigMode = strings.ToLower(sigMode)
	if sigMode == "" || sigMode == aaSigSecp {
		log.Printf("AA init: secp uses implicit EOA owners; nothing to initialize")
		return nil
	}
	if sigMode != aaSigP256 {
		return fmt.Errorf("unsupported AA signature mode %q", sigMode)
	}

	if err := loadConfig(configPath); err != nil {
		return err
	}

	clients, err := newAAClients(utils.TransferCfg.Rpc)
	if err != nil {
		return err
	}
	accounts, err := newAABenchAccounts(utils.TransferCfg.BenchmarkAccounts)
	if err != nil {
		return err
	}
	if len(accounts) == 0 {
		return errors.New("no benchmark accounts configured")
	}

	chainID, err := clients[0].ChainID(context.Background())
	if err != nil {
		return fmt.Errorf("failed to query chain id: %w", err)
	}
	if !chainID.IsUint64() {
		return fmt.Errorf("chain id overflows uint64: %s", chainID)
	}
	deployed, err := aaAccountConfigDeployed(clients[0])
	if err != nil {
		return fmt.Errorf("failed to check AccountConfiguration code: %w", err)
	}
	if !deployed {
		return fmt.Errorf("AccountConfiguration is not deployed at %s; p256 aa-init cannot send config-change transactions on this devnet; deploy/include the AccountConfiguration system contract before running p256 benchmarks", aaAccountConfig.Hex())
	}

	maxFee := utils.ParseGasPriceToBigInt(utils.TransferCfg.GasPriceGwei, 9)
	maxBatchSize := utils.TransferCfg.MaxBatchSize
	if maxBatchSize <= 0 {
		maxBatchSize = 100
	}
	initNonceKey := big.NewInt(0)

	log.Printf("AA init: registering P256Raw owners for %d accounts", len(accounts))
	totalBuilt := 0
	totalSent := 0
	submittedAccounts := make([]*aaBenchAccount, 0, len(accounts))
	for start := 0; start < len(accounts); start += maxBatchSize {
		end := start + maxBatchSize
		if end > len(accounts) {
			end = len(accounts)
		}
		cli := clients[(start/maxBatchSize)%len(clients)]
		rawTxs := make([]string, 0, end-start)
		batchAccounts := make([]*aaBenchAccount, 0, end-start)

		for _, acc := range accounts[start:end] {
			configured, err := aaP256OwnerConfigured(cli, acc)
			if err != nil {
				log.Printf("AA init: owner config check failed for %s: %v", acc.address, err)
				continue
			}
			if configured {
				continue
			}

			seq, err := cli.QueryAANonce(acc.address, initNonceKey)
			if err != nil {
				log.Printf("AA init: AA nonce query failed for %s: %v", acc.address, err)
				continue
			}
			localSeq, err := aaLocalConfigSequence(cli, acc.address)
			if err != nil {
				log.Printf("AA init: config sequence query failed for %s: %v", acc.address, err)
				continue
			}

			raw, err := buildAAP256ConfigRawTx(acc, chainID.Uint64(), initNonceKey, seq, localSeq, maxFee)
			if err != nil {
				log.Printf("AA init: build config tx failed for %s: %v", acc.address, err)
				continue
			}
			rawTxs = append(rawTxs, "0x"+hex.EncodeToString(raw))
			batchAccounts = append(batchAccounts, acc)
		}

		if len(rawTxs) == 0 {
			continue
		}
		totalBuilt += len(rawTxs)
		hashes, err := cli.SendMultipleRawTransactions(rawTxs)
		if err != nil {
			log.Printf("AA init batch [%d:%d] send failed: %v", start, end, err)
		}
		success := 0
		for i, hash := range hashes {
			if i >= len(batchAccounts) {
				break
			}
			if hash == (ethcmn.Hash{}) {
				continue
			}
			batchAccounts[i].seq = batchAccounts[i].seq + 1
			submittedAccounts = append(submittedAccounts, batchAccounts[i])
			success++
		}
		totalSent += success
		log.Printf("AA init batch [%d:%d] sent %d/%d P256 owner config txs", start, end, success, len(rawTxs))
		time.Sleep(200 * time.Millisecond)
	}

	if totalBuilt > 0 && totalSent == 0 {
		return errors.New("AA init built P256 owner config transactions, but none were accepted")
	}
	if totalSent > 0 {
		log.Printf("AA init: waiting for %d P256 owner config transactions to be mined", totalSent)
		if err := waitAAP256OwnerConfigs(clients[0], submittedAccounts, 2*time.Minute); err != nil {
			return err
		}
	}
	log.Printf("AA init: confirmed %d/%d P256 owner config transactions before p256 bench", totalSent, totalBuilt)
	return nil
}

// AABench runs an EIP-8130 benchmark with one call per AA transaction.
func AABench(configPath, sigMode, txKind, contractAddr, nonceKeyArg, payerMode string, gasLimit uint64) error {
	sigMode = strings.ToLower(strings.TrimSpace(sigMode))
	txKind = strings.ToLower(strings.TrimSpace(txKind))
	payerMode = strings.ToLower(strings.TrimSpace(payerMode))
	if sigMode == "" {
		sigMode = aaSigSecp
	}
	if txKind == "" {
		txKind = aaTxNative
	}
	if payerMode == "" {
		payerMode = aaPayerRandom
	}
	nonceLanes, err := parseAANonceLanes(nonceKeyArg)
	if err != nil {
		return err
	}
	if sigMode != aaSigSecp && sigMode != aaSigP256 {
		return fmt.Errorf("unsupported AA signature mode %q", sigMode)
	}
	if txKind != aaTxNative && txKind != aaTxERC20 {
		return fmt.Errorf("unsupported AA tx kind %q", txKind)
	}
	if payerMode != aaPayerSender && payerMode != aaPayerRandom {
		return fmt.Errorf("unsupported AA payer mode %q", payerMode)
	}
	if txKind == aaTxERC20 && contractAddr == "" {
		return errors.New("--contract is required for aa-bench -tx erc20")
	}
	if gasLimit == 0 {
		gasLimit = defaultAAGasLimit(sigMode, txKind, payerMode)
	}

	if err := loadConfig(configPath); err != nil {
		return err
	}

	clients, err := newAAClients(utils.TransferCfg.Rpc)
	if err != nil {
		return err
	}
	accounts, err := newAABenchAccounts(utils.TransferCfg.BenchmarkAccounts)
	if err != nil {
		return err
	}
	if len(accounts) == 0 {
		return errors.New("no benchmark accounts configured")
	}

	chainID, err := clients[0].ChainID(context.Background())
	if err != nil {
		return fmt.Errorf("failed to query chain id: %w", err)
	}
	if !chainID.IsUint64() {
		return fmt.Errorf("chain id overflows uint64: %s", chainID)
	}

	toAddrs := generateAANativeRecipients(len(accounts))
	if txKind == aaTxERC20 {
		toAddrs = generateAddresses()
	}
	if len(toAddrs) == 0 {
		return errors.New("no recipient addresses generated")
	}

	var erc20 ethcmn.Address
	var erc20ABI abi.ABI
	if txKind == aaTxERC20 {
		erc20 = ethcmn.HexToAddress(contractAddr)
		erc20ABI, err = abi.JSON(strings.NewReader(ERC20ABI))
		if err != nil {
			return fmt.Errorf("failed to initialize ERC20 ABI: %w", err)
		}
	}

	concurrency := utils.TransferCfg.Concurrency
	if concurrency <= 0 {
		concurrency = 1
	}
	count := (len(accounts) + concurrency - 1) / concurrency
	maxFee := utils.ParseGasPriceToBigInt(utils.TransferCfg.GasPriceGwei, 9)
	requiredPayerBalance := aaRequiredPayerBalance(maxFee, gasLimit)
	log.Printf("AA bench: waiting for payer candidates to have at least %s wei (gas_limit=%d max_fee_per_gas=%s)", requiredPayerBalance, gasLimit, maxFee)
	if err := waitAABenchmarkPayerBalances(clients[0], accounts, requiredPayerBalance, 2*time.Minute); err != nil {
		return err
	}
	if err := warmupAANonceSequences(clients[0], accounts, nonceLanes); err != nil {
		return err
	}

	log.Printf("AA bench started: sig=%s tx=%s noncekey=%s payer=%s gas_limit=%d accounts=%d concurrency=%d chain_id=%d", sigMode, txKind, nonceLanes.String(), payerMode, gasLimit, len(accounts), concurrency, chainID.Uint64())

	utils.RunTxBatches(func(gIndex int, cli *utils.EthClient, limiter *rate.Limiter) bool {
		start := gIndex * count
		if start >= len(accounts) {
			return false
		}
		end := start + count
		if end > len(accounts) {
			end = len(accounts)
		}
		batchAccounts := accounts[start:end]
		executeAABatch(gIndex, cli, batchAccounts, accounts, toAddrs, chainID.Uint64(), sigMode, txKind, erc20, erc20ABI, nonceLanes, payerMode, gasLimit, limiter)
		time.Sleep(50 * time.Millisecond)
		return true
	})

	return nil
}

func executeAABatch(
	gIndex int,
	cli *utils.EthClient,
	accounts []*aaBenchAccount,
	allAccounts []*aaBenchAccount,
	toAddrs []ethcmn.Address,
	chainID uint64,
	sigMode string,
	txKind string,
	erc20 ethcmn.Address,
	erc20ABI abi.ABI,
	nonceLanes *aaNonceLaneSet,
	payerMode string,
	gasLimit uint64,
	limiter *rate.Limiter,
) {
	maxBatchSize := utils.TransferCfg.MaxBatchSize
	if maxBatchSize <= 0 {
		maxBatchSize = 100
	}
	maxFee := utils.ParseGasPriceToBigInt(utils.TransferCfg.GasPriceGwei, 9)
	ctx := context.Background()

	for start := 0; start < len(accounts); start += maxBatchSize {
		end := start + maxBatchSize
		if end > len(accounts) {
			end = len(accounts)
		}

		expiryBase := uint64(0)
		if nonceLanes.HasNonceFreeLane() {
			var err error
			expiryBase, err = aaLatestBlockTimestamp(cli)
			if err != nil {
				log.Printf("[aa g%d] latest block timestamp query failed: %v", gIndex, err)
				continue
			}
		}

		rawTxs := make([]string, 0, end-start)
		pendingTxs := make([]aaPendingTx, 0, end-start)
		for _, acc := range accounts[start:end] {
			if limiter != nil {
				if err := limiter.Wait(ctx); err != nil {
					log.Printf("[aa g%d] rate limiter error: %v", gIndex, err)
					continue
				}
			}

			acc.lock.Lock()
			acc.ensureNonceLaneState()
			lane := acc.nextAANonceLane(nonceLanes.lanes)
			nonceFree := aaNonceKeyIsMax(lane.key)
			if nonceFree {
				acc.seqByLane[lane.id] = 0
				acc.queriedByLane[lane.id] = true
			} else if !acc.queriedByLane[lane.id] {
				seq, err := cli.QueryAANonce(acc.address, lane.key)
				if err != nil {
					log.Printf("[aa g%d] AA nonce query failed for %s lane %s: %v", gIndex, acc.address, lane.label, err)
					acc.lock.Unlock()
					continue
				}
				acc.seqByLane[lane.id] = seq
				acc.queriedByLane[lane.id] = true
			}
			seq := acc.seqByLane[lane.id]

			payer := selectAAPayer(payerMode, allAccounts)
			call, err := buildAACall(txKind, erc20, erc20ABI, toAddrs)
			if err != nil {
				log.Printf("[aa g%d] build call failed: %v", gIndex, err)
				acc.lock.Unlock()
				continue
			}

			raw, err := buildAABenchmarkRawTx(acc, payer, chainID, lane.key, seq, expiryBase, maxFee, sigMode, gasLimit, call)
			if err != nil {
				log.Printf("[aa g%d] build raw tx failed for %s: %v", gIndex, acc.address, err)
				acc.lock.Unlock()
				continue
			}

			rawTxs = append(rawTxs, "0x"+hex.EncodeToString(raw))
			pendingTxs = append(pendingTxs, aaPendingTx{sender: acc, nonceLaneID: lane.id, nonceFree: nonceFree})
			acc.lock.Unlock()
		}

		if len(rawTxs) == 0 {
			continue
		}
		hashes, err := cli.SendMultipleRawTransactions(rawTxs)
		if err != nil {
			log.Printf("[aa g%d] batch send failed: %v", gIndex, err)
			if strings.Contains(err.Error(), "nonce") || strings.Contains(err.Error(), "sequence") {
				for _, pending := range pendingTxs {
					pending.sender.lock.Lock()
					pending.sender.ensureNonceLaneState()
					pending.sender.queriedByLane[pending.nonceLaneID] = false
					pending.sender.lock.Unlock()
				}
			}
			continue
		}

		success := 0
		for i, hash := range hashes {
			if hash == (ethcmn.Hash{}) {
				continue
			}
			pending := pendingTxs[i]
			pending.sender.lock.Lock()
			pending.sender.ensureNonceLaneState()
			if !pending.nonceFree {
				pending.sender.seqByLane[pending.nonceLaneID]++
			}
			pending.sender.lock.Unlock()
			utils.WriteTxHashAsync(hash.Hex())
			success++
		}
		if success != len(rawTxs) {
			log.Printf("[aa g%d] batch sent %d/%d transactions successfully", gIndex, success, len(rawTxs))
		}
	}
}

func defaultAAGasLimit(sigMode, txKind, payerMode string) uint64 {
	limit := aaDefaultGasLimit
	if txKind == aaTxERC20 {
		limit += aaERC20GasLimitExtra
	}
	if sigMode == aaSigP256 {
		limit += aaP256GasLimitExtra
	}
	if payerMode == aaPayerRandom {
		limit += aaRandomPayerGasExtra
	}
	return limit
}

func aaRequiredPayerBalance(maxFee *big.Int, gasLimit uint64) *big.Int {
	return new(big.Int).Mul(new(big.Int).SetUint64(gasLimit), maxFee)
}

func waitAABenchmarkPayerBalances(cli *utils.EthClient, accounts []*aaBenchAccount, required *big.Int, timeout time.Duration) error {
	if len(accounts) == 0 || required == nil || required.Sign() <= 0 {
		return nil
	}

	pending := append([]*aaBenchAccount(nil), accounts...)
	deadline := time.Now().Add(timeout)
	lastRemaining := -1
	var firstPending *aaBenchAccount
	var firstBalance *big.Int

	for {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		remaining, sampleAccount, sampleBalance, err := aaAccountsBelowBalance(ctx, cli, pending, required)
		cancel()
		if err != nil {
			return fmt.Errorf("AA funding check failed: %w", err)
		}
		if len(remaining) == 0 {
			return nil
		}

		firstPending = sampleAccount
		firstBalance = sampleBalance
		if len(remaining) != lastRemaining {
			log.Printf("AA funding check: waiting for %d/%d payer candidates, first pending=%s balance=%s required=%s", len(remaining), len(accounts), firstPending.address.Hex(), firstBalance, required)
			lastRemaining = len(remaining)
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out waiting for %d/%d AA payer candidates to be funded, first pending=%s balance=%s required=%s", len(remaining), len(accounts), firstPending.address.Hex(), firstBalance, required)
		}

		pending = remaining
		time.Sleep(time.Second)
	}
}

func aaAccountsBelowBalance(ctx context.Context, cli *utils.EthClient, accounts []*aaBenchAccount, required *big.Int) ([]*aaBenchAccount, *aaBenchAccount, *big.Int, error) {
	remaining := make([]*aaBenchAccount, 0)
	var sampleAccount *aaBenchAccount
	var sampleBalance *big.Int

	for start := 0; start < len(accounts); start += aaBalanceCheckBatchSize {
		end := start + aaBalanceCheckBatchSize
		if end > len(accounts) {
			end = len(accounts)
		}

		addrs := make([]ethcmn.Address, 0, end-start)
		for _, acc := range accounts[start:end] {
			addrs = append(addrs, acc.address)
		}
		balances, err := cli.BatchBalances(ctx, addrs)
		if err != nil {
			return nil, nil, nil, err
		}

		for i, balance := range balances {
			if balance == nil {
				balance = big.NewInt(0)
			}
			if balance.Cmp(required) >= 0 {
				continue
			}
			acc := accounts[start+i]
			remaining = append(remaining, acc)
			if sampleAccount == nil {
				sampleAccount = acc
				sampleBalance = new(big.Int).Set(balance)
			}
		}
	}

	return remaining, sampleAccount, sampleBalance, nil
}

func warmupAANonceSequences(cli *utils.EthClient, accounts []*aaBenchAccount, nonceLanes *aaNonceLaneSet) error {
	if nonceLanes == nil || len(nonceLanes.lanes) == 0 {
		return nil
	}

	for _, lane := range nonceLanes.lanes {
		if aaNonceKeyIsMax(lane.key) {
			for _, acc := range accounts {
				acc.ensureNonceLaneState()
				acc.seqByLane[lane.id] = 0
				acc.queriedByLane[lane.id] = true
			}
			continue
		}

		log.Printf("AA bench: preloading nonce lane %s for %d accounts", lane.label, len(accounts))
		for start := 0; start < len(accounts); start += aaBalanceCheckBatchSize {
			end := start + aaBalanceCheckBatchSize
			if end > len(accounts) {
				end = len(accounts)
			}

			addrs := make([]ethcmn.Address, 0, end-start)
			for _, acc := range accounts[start:end] {
				addrs = append(addrs, acc.address)
			}

			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			seqs, err := cli.BatchAANonces(ctx, addrs, lane.key)
			cancel()
			if err != nil {
				return fmt.Errorf("AA nonce preload failed for lane %s accounts [%d:%d]: %w", lane.label, start, end, err)
			}

			for i, seq := range seqs {
				acc := accounts[start+i]
				acc.ensureNonceLaneState()
				acc.seqByLane[lane.id] = seq
				acc.queriedByLane[lane.id] = true
			}
		}
	}

	return nil
}

func generateAANativeRecipients(count int) []ethcmn.Address {
	addrs := make([]ethcmn.Address, 0, count)
	for i := 0; i < count; i++ {
		seed := fmt.Sprintf("xlayer-aa-native-recipient-%d", i)
		hash := crypto.Keccak256([]byte(seed))
		addrs = append(addrs, ethcmn.BytesToAddress(hash[12:]))
	}
	return addrs
}

func buildAACall(txKind string, erc20 ethcmn.Address, erc20ABI abi.ABI, toAddrs []ethcmn.Address) (aaCallEntry, error) {
	to := toAddrs[mathrand.Intn(len(toAddrs))]
	if txKind == aaTxNative {
		return aaCallEntry{To: to.Bytes(), Data: nil}, nil
	}
	data, err := erc20ABI.Pack("transfer", to, big.NewInt(1))
	if err != nil {
		return aaCallEntry{}, err
	}
	return aaCallEntry{To: erc20.Bytes(), Data: data}, nil
}

func parseAANonceLanes(raw string) (*aaNonceLaneSet, error) {
	arg := strings.TrimSpace(strings.ToLower(raw))
	if arg == "" {
		arg = "0"
	}

	parts := strings.Split(arg, ",")
	if len(parts) == 1 {
		key, label, err := parseAANonceKey(parts[0])
		if err != nil {
			return nil, err
		}
		return &aaNonceLaneSet{
			lanes:   []aaNonceLane{{id: aaNonceLaneID(key), label: label, key: key}},
			display: label,
		}, nil
	}
	if len(parts) != 2 {
		return nil, fmt.Errorf("invalid --noncekey %q: use 0, max, or start,end", raw)
	}

	start, startLabel, err := parseAANonceKey(parts[0])
	if err != nil {
		return nil, err
	}
	end, endLabel, err := parseAANonceKey(parts[1])
	if err != nil {
		return nil, err
	}
	if startLabel == "max" || endLabel == "max" {
		return nil, fmt.Errorf("invalid --noncekey %q: use max by itself, ranges must be finite integer lanes", raw)
	}
	if start.Cmp(end) > 0 {
		return nil, fmt.Errorf("invalid --noncekey %q: range start is greater than end", raw)
	}
	if !start.IsUint64() || !end.IsUint64() {
		return nil, fmt.Errorf("invalid --noncekey %q: range bounds must fit uint64", raw)
	}

	startU64 := start.Uint64()
	endU64 := end.Uint64()
	diff := endU64 - startU64
	if diff >= aaMaxNonceLanes {
		return nil, fmt.Errorf("invalid --noncekey %q: range contains more than %d lanes", raw, aaMaxNonceLanes)
	}

	lanes := make([]aaNonceLane, 0, diff+1)
	for offset := uint64(0); offset <= diff; offset++ {
		key := new(big.Int).SetUint64(startU64 + offset)
		label := key.String()
		lanes = append(lanes, aaNonceLane{id: aaNonceLaneID(key), label: label, key: key})
	}
	return &aaNonceLaneSet{lanes: lanes, display: fmt.Sprintf("%s,%s", startLabel, endLabel)}, nil
}

func parseAANonceKey(raw string) (*big.Int, string, error) {
	arg := strings.TrimSpace(strings.ToLower(raw))
	if arg == "" {
		return nil, "", errors.New("invalid --noncekey: empty nonce key")
	}
	if arg == "max" {
		return cloneBig(aaU256Max), "max", nil
	}

	key := new(big.Int)
	var ok bool
	if strings.HasPrefix(arg, "0x") {
		if len(arg) == 2 {
			return nil, "", fmt.Errorf("invalid --noncekey %q", raw)
		}
		_, ok = key.SetString(arg[2:], 16)
	} else {
		_, ok = key.SetString(arg, 10)
	}
	if !ok || key.Sign() < 0 {
		return nil, "", fmt.Errorf("invalid --noncekey %q: expected 0, max, or start,end", raw)
	}
	if key.Cmp(aaU256Max) > 0 {
		return nil, "", fmt.Errorf("invalid --noncekey %q: value exceeds U256::MAX", raw)
	}
	return key, key.String(), nil
}

func (set *aaNonceLaneSet) String() string {
	if set == nil || set.display == "" {
		return "0"
	}
	return set.display
}

func (set *aaNonceLaneSet) HasNonceFreeLane() bool {
	if set == nil {
		return false
	}
	for _, lane := range set.lanes {
		if aaNonceKeyIsMax(lane.key) {
			return true
		}
	}
	return false
}

func (acc *aaBenchAccount) ensureNonceLaneState() {
	if acc.seqByLane == nil {
		acc.seqByLane = make(map[string]uint64)
	}
	if acc.queriedByLane == nil {
		acc.queriedByLane = make(map[string]bool)
	}
}

func (acc *aaBenchAccount) nextAANonceLane(lanes []aaNonceLane) aaNonceLane {
	if len(lanes) == 0 {
		key := big.NewInt(0)
		return aaNonceLane{id: aaNonceLaneID(key), label: "0", key: key}
	}
	lane := lanes[acc.nextLane%uint64(len(lanes))]
	acc.nextLane++
	return lane
}

func selectAAPayer(mode string, allAccounts []*aaBenchAccount) *aaBenchAccount {
	if mode == aaPayerSender {
		return nil
	}
	return allAccounts[mathrand.Intn(len(allAccounts))]
}

func aaNonceLaneID(key *big.Int) string {
	if key == nil {
		return "0"
	}
	return key.Text(16)
}

func aaSequenceForNonceKey(nonceKey *big.Int, seq uint64) uint64 {
	if aaNonceKeyIsMax(nonceKey) {
		return 0
	}
	return seq
}

func aaExpiryForNonceKey(nonceKey *big.Int, latestBlockTimestamp uint64) uint64 {
	if aaNonceKeyIsMax(nonceKey) {
		// U256::MAX is nonce-free. Reth admits these only inside
		// (block_timestamp + 3, block_timestamp + 30], so use the L2
		// timestamp rather than local wall-clock time.
		return latestBlockTimestamp + aaNonceFreeExpiryOffset
	}
	return 0
}

func aaLatestBlockTimestamp(cli *utils.EthClient) (uint64, error) {
	header, err := cli.HeaderByNumber(context.Background(), nil)
	if err != nil {
		return 0, err
	}
	return header.Time, nil
}

func aaNonceKeyIsMax(nonceKey *big.Int) bool {
	return nonceKey != nil && nonceKey.Cmp(aaU256Max) == 0
}

func cloneBig(v *big.Int) *big.Int {
	if v == nil {
		return big.NewInt(0)
	}
	return new(big.Int).Set(v)
}

func buildAABenchmarkRawTx(acc, payer *aaBenchAccount, chainID uint64, nonceKey *big.Int, seq, expiryBase uint64, maxFee *big.Int, sigMode string, gasLimit uint64, call aaCallEntry) ([]byte, error) {
	tx := &aaTx{
		ChainID:              chainID,
		NonceKey:             cloneBig(nonceKey),
		NonceSequence:        aaSequenceForNonceKey(nonceKey, seq),
		Expiry:               aaExpiryForNonceKey(nonceKey, expiryBase),
		MaxPriorityFeePerGas: big.NewInt(0),
		MaxFeePerGas:         new(big.Int).Set(maxFee),
		GasLimit:             gasLimit,
		AccountChanges:       []interface{}{},
		Calls:                [][]aaCallEntry{{call}},
	}
	if payer != nil {
		payerAddr := payer.address
		tx.Payer = &payerAddr
	}
	if sigMode == aaSigP256 {
		sender := acc.address
		tx.Sender = &sender
	}

	senderHash, err := tx.senderSignatureHash()
	if err != nil {
		return nil, err
	}
	if sigMode == aaSigP256 {
		tx.SenderAuth, err = signP256Explicit(acc.p256, senderHash)
	} else {
		tx.SenderAuth, err = signK1Bare(acc.privateKey, senderHash)
	}
	if err != nil {
		return nil, err
	}

	if payer != nil {
		payerHash, err := tx.payerSignatureHash(acc.address)
		if err != nil {
			return nil, err
		}
		tx.PayerAuth, err = signK1Explicit(payer.privateKey, payerHash)
		if err != nil {
			return nil, err
		}
	}

	return tx.encodeRaw()
}

func buildAAP256ConfigRawTx(acc *aaBenchAccount, chainID uint64, nonceKey *big.Int, aaSeq, localSeq uint64, maxFee *big.Int) ([]byte, error) {
	ownerChange := aaOwnerChangeRLP{
		ChangeType: aaOwnerAuthorizeType,
		Verifier:   aaP256RawVerifier.Bytes(),
		OwnerID:    acc.p256.ownerID,
		Scope:      aaOwnerScopeSenderPayer,
	}
	configDigest := aaConfigChangeDigest(acc.address, chainID, localSeq, []aaOwnerChangeRLP{ownerChange})
	authorizerAuth, err := signK1Explicit(acc.privateKey, configDigest)
	if err != nil {
		return nil, err
	}
	configEntry := []interface{}{
		aaConfigChangeType,
		chainID,
		localSeq,
		[]aaOwnerChangeRLP{ownerChange},
		authorizerAuth,
	}
	payerAddr := acc.address
	tx := &aaTx{
		ChainID:              chainID,
		NonceKey:             cloneBig(nonceKey),
		NonceSequence:        aaSeq,
		Expiry:               0,
		MaxPriorityFeePerGas: big.NewInt(0),
		MaxFeePerGas:         new(big.Int).Set(maxFee),
		GasLimit:             aaP256InitGasLimit,
		AccountChanges:       []interface{}{configEntry},
		Calls:                [][]aaCallEntry{},
		Payer:                &payerAddr,
	}

	senderHash, err := tx.senderSignatureHash()
	if err != nil {
		return nil, err
	}
	tx.SenderAuth, err = signK1Bare(acc.privateKey, senderHash)
	if err != nil {
		return nil, err
	}
	payerHash, err := tx.payerSignatureHash(acc.address)
	if err != nil {
		return nil, err
	}
	tx.PayerAuth, err = signK1Explicit(acc.privateKey, payerHash)
	if err != nil {
		return nil, err
	}
	return tx.encodeRaw()
}

func (tx *aaTx) senderSigningFields() []interface{} {
	return []interface{}{
		tx.ChainID,
		optionalAddressBytes(tx.Sender),
		tx.NonceKey,
		tx.NonceSequence,
		tx.Expiry,
		tx.MaxPriorityFeePerGas,
		tx.MaxFeePerGas,
		tx.GasLimit,
		tx.AccountChanges,
		tx.Calls,
		optionalAddressBytes(tx.Payer),
	}
}

func (tx *aaTx) payerSigningFields(resolvedSender ethcmn.Address) []interface{} {
	sender := tx.Sender
	if sender == nil {
		sender = &resolvedSender
	}
	return []interface{}{
		tx.ChainID,
		optionalAddressBytes(sender),
		tx.NonceKey,
		tx.NonceSequence,
		tx.Expiry,
		tx.MaxPriorityFeePerGas,
		tx.MaxFeePerGas,
		tx.GasLimit,
		tx.AccountChanges,
		tx.Calls,
	}
}

func (tx *aaTx) fullFields() []interface{} {
	fields := tx.senderSigningFields()
	fields = append(fields, tx.SenderAuth, tx.PayerAuth)
	return fields
}

func (tx *aaTx) senderSignatureHash() ([]byte, error) {
	return aaHashPayload(aaTxType, tx.senderSigningFields())
}

func (tx *aaTx) payerSignatureHash(resolvedSender ethcmn.Address) ([]byte, error) {
	return aaHashPayload(aaPayerType, tx.payerSigningFields(resolvedSender))
}

func (tx *aaTx) encodeRaw() ([]byte, error) {
	payload, err := rlp.EncodeToBytes(tx.fullFields())
	if err != nil {
		return nil, err
	}
	raw := make([]byte, 0, 1+len(payload))
	raw = append(raw, aaTxType)
	raw = append(raw, payload...)
	return raw, nil
}

func aaHashPayload(domain byte, fields []interface{}) ([]byte, error) {
	payload, err := rlp.EncodeToBytes(fields)
	if err != nil {
		return nil, err
	}
	preimage := make([]byte, 0, 1+len(payload))
	preimage = append(preimage, domain)
	preimage = append(preimage, payload...)
	hash := crypto.Keccak256(preimage)
	return hash, nil
}

func optionalAddressBytes(addr *ethcmn.Address) []byte {
	if addr == nil {
		return []byte{}
	}
	return addr.Bytes()
}

func signK1Bare(privateKey *ecdsa.PrivateKey, hash []byte) ([]byte, error) {
	return crypto.Sign(hash, privateKey)
}

func signK1Explicit(privateKey *ecdsa.PrivateKey, hash []byte) ([]byte, error) {
	sig, err := signK1Bare(privateKey, hash)
	if err != nil {
		return nil, err
	}
	auth := make([]byte, 0, 20+len(sig))
	auth = append(auth, aaK1Verifier.Bytes()...)
	auth = append(auth, sig...)
	return auth, nil
}

func signP256Explicit(key *aaP256Key, hash []byte) ([]byte, error) {
	if key == nil || key.privateKey == nil {
		return nil, errors.New("missing P256 key")
	}
	r, s, err := ecdsa.Sign(cryptorand.Reader, key.privateKey, hash)
	if err != nil {
		return nil, err
	}
	if s.Cmp(aaP256HalfOrder) > 0 {
		s = new(big.Int).Sub(key.privateKey.Curve.Params().N, s)
	}
	auth := make([]byte, 0, 20+128)
	auth = append(auth, aaP256RawVerifier.Bytes()...)
	auth = append(auth, key.publicKey...)
	auth = append(auth, leftPadBig(r, 32)...)
	auth = append(auth, leftPadBig(s, 32)...)
	return auth, nil
}

func newAAClients(rpcs []string) ([]*utils.EthClient, error) {
	clients := make([]*utils.EthClient, 0, len(rpcs))
	for _, rpcURL := range rpcs {
		cli, err := utils.NewEthClient(rpcURL)
		if err != nil {
			return nil, err
		}
		clients = append(clients, cli)
	}
	if len(clients) == 0 {
		return nil, errors.New("no RPC endpoints configured")
	}
	return clients, nil
}

func newAABenchAccounts(privateKeys []string) ([]*aaBenchAccount, error) {
	accounts := make([]*aaBenchAccount, 0, len(privateKeys))
	for _, raw := range privateKeys {
		pkHex := strings.TrimPrefix(strings.TrimSpace(raw), "0x")
		privateKey, err := crypto.HexToECDSA(pkHex)
		if err != nil {
			return nil, fmt.Errorf("invalid benchmark private key: %w", err)
		}
		p256Key, err := deriveP256Key(privateKey)
		if err != nil {
			return nil, err
		}
		accounts = append(accounts, &aaBenchAccount{
			seqByLane:     make(map[string]uint64),
			queriedByLane: make(map[string]bool),
			nextLane:      uint64(len(accounts)),
			privateKey:    privateKey,
			address:       utils.GetEthAddressFromPK(privateKey),
			p256:          p256Key,
		})
	}
	return accounts, nil
}

func deriveP256Key(secpKey *ecdsa.PrivateKey) (*aaP256Key, error) {
	curve := elliptic.P256()
	n := curve.Params().N
	nMinusOne := new(big.Int).Sub(n, big.NewInt(1))
	d := new(big.Int).SetBytes(crypto.FromECDSA(secpKey))
	d.Mod(d, nMinusOne)
	d.Add(d, big.NewInt(1))

	priv := &ecdsa.PrivateKey{PublicKey: ecdsa.PublicKey{Curve: curve}, D: d}
	priv.PublicKey.X, priv.PublicKey.Y = curve.ScalarBaseMult(leftPadBig(d, 32))
	if priv.PublicKey.X == nil || priv.PublicKey.Y == nil {
		return nil, errors.New("failed to derive P256 public key")
	}
	pub := make([]byte, 0, 64)
	pub = append(pub, leftPadBig(priv.PublicKey.X, 32)...)
	pub = append(pub, leftPadBig(priv.PublicKey.Y, 32)...)
	return &aaP256Key{privateKey: priv, publicKey: pub, ownerID: crypto.Keccak256(pub)}, nil
}

func aaConfigChangeDigest(account ethcmn.Address, chainID, sequence uint64, ownerChanges []aaOwnerChangeRLP) []byte {
	concat := make([]byte, 0, len(ownerChanges)*32)
	for _, op := range ownerChanges {
		buf := make([]byte, 128)
		buf[31] = op.ChangeType
		copy(buf[44:64], op.Verifier)
		copy(buf[64:96], op.OwnerID)
		buf[127] = op.Scope
		concat = append(concat, crypto.Keccak256(buf)...)
	}
	ownerChangesHash := crypto.Keccak256(concat)

	buf := make([]byte, 160)
	copy(buf[:32], aaConfigTypehash)
	copy(buf[44:64], account.Bytes())
	binary.BigEndian.PutUint64(buf[88:96], chainID)
	binary.BigEndian.PutUint64(buf[120:128], sequence)
	copy(buf[128:160], ownerChangesHash)
	return crypto.Keccak256(buf)
}

func waitAAP256OwnerConfigs(cli *utils.EthClient, accounts []*aaBenchAccount, timeout time.Duration) error {
	if len(accounts) == 0 {
		return nil
	}
	pending := append([]*aaBenchAccount(nil), accounts...)
	deadline := time.Now().Add(timeout)
	var lastErr error

	for {
		remaining := pending[:0]
		for _, acc := range pending {
			configured, err := aaP256OwnerConfigured(cli, acc)
			if err != nil {
				lastErr = err
				remaining = append(remaining, acc)
				continue
			}
			if !configured {
				remaining = append(remaining, acc)
			}
		}
		if len(remaining) == 0 {
			return nil
		}
		if time.Now().After(deadline) {
			if lastErr != nil {
				return fmt.Errorf("timed out waiting for %d/%d P256 owner configs, last error: %w", len(remaining), len(accounts), lastErr)
			}
			return fmt.Errorf("timed out waiting for %d/%d P256 owner configs, first pending account %s", len(remaining), len(accounts), remaining[0].address.Hex())
		}
		pending = remaining
		time.Sleep(time.Second)
	}
}

func aaAccountConfigDeployed(cli *utils.EthClient) (bool, error) {
	code, err := cli.CodeAt(context.Background(), aaAccountConfig, nil)
	if err != nil {
		return false, err
	}
	return len(code) > 0, nil
}

func aaP256OwnerConfigured(cli *utils.EthClient, acc *aaBenchAccount) (bool, error) {
	slot := aaOwnerConfigSlot(acc.address, acc.p256.ownerID)
	word, err := cli.StorageAt(context.Background(), aaAccountConfig, slot, nil)
	if err != nil {
		return false, err
	}
	padded := leftPadBytes(word, 32)
	verifier := ethcmn.BytesToAddress(padded[12:32])
	scope := padded[11]
	return verifier == aaP256RawVerifier && (scope == 0 || scope&aaOwnerScopeSender != 0), nil
}

func aaLocalConfigSequence(cli *utils.EthClient, account ethcmn.Address) (uint64, error) {
	slot := aaAccountStateSlot(account)
	word, err := cli.StorageAt(context.Background(), aaAccountConfig, slot, nil)
	if err != nil {
		return 0, err
	}
	padded := leftPadBytes(word, 32)
	return binary.BigEndian.Uint64(padded[16:24]), nil
}

func aaOwnerConfigSlot(account ethcmn.Address, ownerID []byte) ethcmn.Hash {
	innerPreimage := make([]byte, 0, 64)
	innerPreimage = append(innerPreimage, leftPadBytes(ownerID, 32)...)
	innerPreimage = append(innerPreimage, aaStorageSlotZero...)
	inner := crypto.Keccak256(innerPreimage)

	outerPreimage := make([]byte, 0, 64)
	outerPreimage = append(outerPreimage, addressABIWord(account)...)
	outerPreimage = append(outerPreimage, inner...)
	return ethcmn.BytesToHash(crypto.Keccak256(outerPreimage))
}

func aaAccountStateSlot(account ethcmn.Address) ethcmn.Hash {
	preimage := make([]byte, 0, 64)
	preimage = append(preimage, addressABIWord(account)...)
	preimage = append(preimage, aaStorageSlotOne...)
	return ethcmn.BytesToHash(crypto.Keccak256(preimage))
}

func addressABIWord(addr ethcmn.Address) []byte {
	out := make([]byte, 32)
	copy(out[12:], addr.Bytes())
	return out
}

func uint256Bytes(v *big.Int) []byte {
	return leftPadBig(v, 32)
}

func leftPadBig(v *big.Int, size int) []byte {
	if v == nil {
		return make([]byte, size)
	}
	return leftPadBytes(v.Bytes(), size)
}

func leftPadBytes(in []byte, size int) []byte {
	if len(in) >= size {
		return in[len(in)-size:]
	}
	out := make([]byte, size)
	copy(out[size-len(in):], in)
	return out
}
