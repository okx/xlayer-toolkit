package utils

import (
	"bufio"
	"crypto/ecdsa"
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
		if err != nil || io.EOF == err {
			break
		}

		lines = append(lines, strings.TrimSpace(line))
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
