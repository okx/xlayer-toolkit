package bench

import (
	"bufio"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ethereum/go-ethereum/crypto"
)

func GetConfigFilePath(nums int) (string, error) {
	accountsFile := fmt.Sprintf("testdata/accounts/accounts-%d.txt", nums)

	if err := EnsureAccountsFile(accountsFile, nums); err != nil {
		return "", fmt.Errorf("failed to ensure accounts file: %v", err)
	}
	return accountsFile, nil
}

func EnsureAccountsFile(path string, nums int) error {
	if nums <= 0 {
		return errors.New("nums must be greater than 0")
	}

	// 如果文件已存在，直接返回
	if _, err := os.Stat(path); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return err
	}

	// 创建目录
	dir := filepath.Dir(path)
	if dir != "." && dir != "" {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return err
		}
	}

	// 创建文件（此时保证不存在）
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	defer f.Close()

	w := bufio.NewWriter(f)
	defer w.Flush()

	for i := 0; i < nums; i++ {
		key, err := crypto.GenerateKey()
		if err != nil {
			return err
		}

		privHex := strings.ToUpper(hex.EncodeToString(crypto.FromECDSA(key)))

		if _, err := w.WriteString(privHex + "\n"); err != nil {
			return err
		}
	}

	return w.Flush()
}
