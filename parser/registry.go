package erc8021

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/ethclient"
)

// ErrNotDeployed is returned when an eth_call to a registry address returns
// empty data, which means no contract is deployed at that address.
var ErrNotDeployed = errors.New("no contract deployed at registry address")

// builderCodesABI is the minimal ABI for BuilderCodes.sol functions we query.
const builderCodesABI = `[
  {"name":"isRegistered","type":"function","stateMutability":"view",
   "inputs":[{"name":"code","type":"string"}],
   "outputs":[{"name":"","type":"bool"}]},
  {"name":"payoutAddress","type":"function","stateMutability":"view",
   "inputs":[{"name":"code","type":"string"}],
   "outputs":[{"name":"","type":"address"}]},
  {"name":"toTokenId","type":"function","stateMutability":"pure",
   "inputs":[{"name":"code","type":"string"}],
   "outputs":[{"name":"tokenId","type":"uint256"}]},
  {"name":"ownerOf","type":"function","stateMutability":"view",
   "inputs":[{"name":"tokenId","type":"uint256"}],
   "outputs":[{"name":"","type":"address"}]},
  {"name":"codeURI","type":"function","stateMutability":"view",
   "inputs":[{"name":"code","type":"string"}],
   "outputs":[{"name":"","type":"string"}]}
]`

// CodeInfo holds on-chain data fetched from a BuilderCodes registry for one code.
type CodeInfo struct {
	// Code is the attribution code string.
	Code string
	// IsRegistered reports whether the code exists in the registry.
	IsRegistered bool
	// Owner is the ERC-721 token owner (populated when IsRegistered is true).
	Owner common.Address
	// PayoutAddress is the registered payout address (populated when IsRegistered is true).
	PayoutAddress common.Address
	// CodeURI is the metadata URI for the code (populated when IsRegistered is true).
	CodeURI string
}

// QueryRegistry queries the BuilderCodes contract at registryAddr (via rpcURL)
// for each builder code and returns one CodeInfo per entry.
//
// rpcURL must point to the chain that hosts the registry contract.
func QueryRegistry(ctx context.Context, rpcURL string, registryAddr [20]byte, codes []string) ([]CodeInfo, error) {
	contractABI, err := abi.JSON(strings.NewReader(builderCodesABI))
	if err != nil {
		return nil, fmt.Errorf("erc8021/registry: parse ABI: %w", err)
	}

	client, err := ethclient.DialContext(ctx, rpcURL)
	if err != nil {
		return nil, fmt.Errorf("erc8021/registry: dial %s: %w", rpcURL, err)
	}
	defer client.Close()

	addr := common.Address(registryAddr)
	infos := make([]CodeInfo, 0, len(codes))
	for _, code := range codes {
		info, err := queryOneCode(ctx, client, contractABI, addr, code)
		if err != nil {
			return nil, err
		}
		infos = append(infos, info)
	}
	return infos, nil
}

func queryOneCode(ctx context.Context, client *ethclient.Client, contractABI abi.ABI, addr common.Address, code string) (CodeInfo, error) {
	info := CodeInfo{Code: code}

	isReg, err := abiCallBool(ctx, client, contractABI, addr, "isRegistered", code)
	if err != nil {
		return info, fmt.Errorf("erc8021/registry: isRegistered(%q): %w", code, err)
	}
	info.IsRegistered = isReg
	if !isReg {
		return info, nil
	}

	payout, err := abiCallAddress(ctx, client, contractABI, addr, "payoutAddress", code)
	if err != nil {
		return info, fmt.Errorf("erc8021/registry: payoutAddress(%q): %w", code, err)
	}
	info.PayoutAddress = payout

	tokenID, err := abiCallUint256(ctx, client, contractABI, addr, "toTokenId", code)
	if err != nil {
		return info, fmt.Errorf("erc8021/registry: toTokenId(%q): %w", code, err)
	}
	owner, err := abiCallAddress(ctx, client, contractABI, addr, "ownerOf", tokenID)
	if err != nil {
		return info, fmt.Errorf("erc8021/registry: ownerOf(%q): %w", code, err)
	}
	info.Owner = owner

	uri, err := abiCallString(ctx, client, contractABI, addr, "codeURI", code)
	if err != nil {
		return info, fmt.Errorf("erc8021/registry: codeURI(%q): %w", code, err)
	}
	info.CodeURI = uri

	return info, nil
}

// ── low-level ABI call helpers ─────────────────────────────────────────────

func abiCallString(ctx context.Context, client *ethclient.Client, contractABI abi.ABI, addr common.Address, method string, args ...any) (string, error) {
	out, err := abiCall(ctx, client, contractABI, addr, method, args...)
	if err != nil {
		return "", err
	}
	v, ok := out[0].(string)
	if !ok {
		return "", fmt.Errorf("expected string, got %T", out[0])
	}
	return v, nil
}

func abiCallBool(ctx context.Context, client *ethclient.Client, contractABI abi.ABI, addr common.Address, method string, args ...any) (bool, error) {
	out, err := abiCall(ctx, client, contractABI, addr, method, args...)
	if err != nil {
		return false, err
	}
	v, ok := out[0].(bool)
	if !ok {
		return false, fmt.Errorf("expected bool, got %T", out[0])
	}
	return v, nil
}

func abiCallAddress(ctx context.Context, client *ethclient.Client, contractABI abi.ABI, addr common.Address, method string, args ...any) (common.Address, error) {
	out, err := abiCall(ctx, client, contractABI, addr, method, args...)
	if err != nil {
		return common.Address{}, err
	}
	v, ok := out[0].(common.Address)
	if !ok {
		return common.Address{}, fmt.Errorf("expected address, got %T", out[0])
	}
	return v, nil
}

func abiCallUint256(ctx context.Context, client *ethclient.Client, contractABI abi.ABI, addr common.Address, method string, args ...any) (*big.Int, error) {
	out, err := abiCall(ctx, client, contractABI, addr, method, args...)
	if err != nil {
		return nil, err
	}
	v, ok := out[0].(*big.Int)
	if !ok {
		return nil, fmt.Errorf("expected *big.Int, got %T", out[0])
	}
	return v, nil
}

func abiCall(ctx context.Context, client *ethclient.Client, contractABI abi.ABI, addr common.Address, method string, args ...any) ([]any, error) {
	data, err := contractABI.Pack(method, args...)
	if err != nil {
		return nil, fmt.Errorf("pack %s: %w", method, err)
	}
	result, err := client.CallContract(ctx, ethereum.CallMsg{To: &addr, Data: data}, nil)
	if err != nil {
		return nil, fmt.Errorf("eth_call %s: %w", method, err)
	}
	if len(result) == 0 {
		return nil, ErrNotDeployed
	}
	out, err := contractABI.Unpack(method, result)
	if err != nil {
		return nil, fmt.Errorf("unpack %s: %w", method, err)
	}
	return out, nil
}
