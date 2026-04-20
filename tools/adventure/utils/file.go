package utils

import (
	"bufio"
	"crypto/ecdsa"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"strings"

	ethcmm "github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// ReadDataFromFile reads lines from a file and returns them as a slice
func ReadDataFromFile(filepath string) []string {
	f, err := os.Open(filepath)
	if err != nil {
		panic(fmt.Errorf("failed to open file %s, error: %s\n", filepath, err.Error()))
	}
	defer func(f *os.File) {
		err := f.Close()
		if err != nil {
			log.Println(fmt.Errorf("failed to close file %s, error: %s\n", filepath, err.Error()))
		}
	}(f)

	log.Printf("data is being loaded from path: %s, please wait\n", filepath)

	var lines []string
	count := 0
	rd := bufio.NewReader(f)
	for {
		line, err := rd.ReadString('\n')
		line = strings.TrimSpace(line)
		if err != nil || io.EOF == err {
			if line != "" {
				lines = append(lines, line)
				count++
			}
			break
		}
		if line == "" {
			continue
		}

		lines = append(lines, line)
		count++
	}

	log.Printf("%d records are loaded\n", count)
	return lines
}

// GetEthAddressFromPK converts an ECDSA private key to an Ethereum address
func GetEthAddressFromPK(privateKey *ecdsa.PrivateKey) ethcmm.Address {
	pubkeyECDSA, ok := privateKey.Public().(*ecdsa.PublicKey)
	if !ok {
		panic(fmt.Errorf("convert into pubkey failed"))
	}
	return crypto.PubkeyToAddress(*pubkeyECDSA)
}

func WriteJSONToFile(m interface{}, file string) error {
	f, err := os.OpenFile(file, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return fmt.Errorf("failed to open file %s, error: %s\n", file, err.Error())
	}
	defer func(f *os.File) {
		err := f.Close()
		if err != nil {
			log.Println(fmt.Errorf("failed to close file %s, error: %s\n", file, err.Error()))
		}
	}(f)

	jsonData, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal data to JSON, error: %s\n", err.Error())
	}

	if _, err := f.Write(jsonData); err != nil {
		return fmt.Errorf("failed to write JSON data to file %s, error: %s\n", file, err.Error())
	}

	return nil
}
