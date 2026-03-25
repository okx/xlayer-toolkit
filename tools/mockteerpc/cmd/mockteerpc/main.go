// Command mockteerpc runs a standalone mock TeeRollup HTTP server for local development and curl testing.
//
// Usage:
//
//	go run ./mock/cmd/mockteerpc [--addr :8090]
package main

import (
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/crypto"
)

type response struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    *data  `json:"data"`
}

type data struct {
	Height    uint64 `json:"height"`
	AppHash   string `json:"appHash"`
	BlockHash string `json:"blockHash"`
}

type server struct {
	mu        sync.RWMutex
	height    uint64
	errorRate float64
	maxDelay  time.Duration
}

func (s *server) tick() {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for range ticker.C {
		delta := uint64(rand.Intn(50) + 1)
		s.mu.Lock()
		s.height += delta
		s.mu.Unlock()
		s.mu.RLock()
		log.Printf("tick: height=%d delta=%d", s.height, delta)
		s.mu.RUnlock()
	}
}

func computeAppHash(height uint64) [32]byte {
	var buf [8]byte
	binary.BigEndian.PutUint64(buf[:], height)
	return crypto.Keccak256Hash(buf[:])
}

func computeBlockHash(appHash [32]byte) [32]byte {
	return crypto.Keccak256Hash(appHash[:])
}

func (s *server) handleConfirmedBlockInfo(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	log.Printf("[mockteerpc] received %s %s from %s", r.Method, r.URL.Path, r.RemoteAddr)

	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Random delay in [0, maxDelay].
	if s.maxDelay > 0 {
		delay := time.Duration(rand.Int63n(int64(s.maxDelay) + 1))
		time.Sleep(delay)
	}

	w.Header().Set("Content-Type", "application/json")

	if s.errorRate > 0 && rand.Float64() < s.errorRate {
		writeErrorResponse(w)
		log.Printf("[mockteerpc] responded with error (took %s)", time.Since(start))
		return
	}

	s.mu.RLock()
	h := s.height
	s.mu.RUnlock()

	appHash := computeAppHash(h)
	blockHash := computeBlockHash(appHash)

	appHashStr := "0x" + hex.EncodeToString(appHash[:])
	resp := response{
		Code:    0,
		Message: "OK",
		Data: &data{
			Height:    h,
			AppHash:   appHashStr,
			BlockHash: "0x" + hex.EncodeToString(blockHash[:]),
		},
	}
	_ = json.NewEncoder(w).Encode(resp)
	log.Printf("[mockteerpc] responded height=%d appHash=%s (took %s)", h, appHashStr[:10]+"...", time.Since(start))
}

func writeErrorResponse(w http.ResponseWriter) {
	type nullableData struct {
		Height    *uint64 `json:"height"`
		AppHash   *string `json:"appHash"`
		BlockHash *string `json:"blockHash"`
	}
	type respNoData struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	}
	type respWithData struct {
		Code    int           `json:"code"`
		Message string        `json:"message"`
		Data    *nullableData `json:"data"`
	}

	switch rand.Intn(3) {
	case 0: // code != 0, no data field
		_ = json.NewEncoder(w).Encode(respNoData{Code: 1, Message: "internal server error"})
	case 1: // code == 0, data is null
		_ = json.NewEncoder(w).Encode(respWithData{Code: 0, Message: "OK", Data: nil})
	case 2: // code == 0, data present but all fields null
		_ = json.NewEncoder(w).Encode(respWithData{Code: 0, Message: "OK", Data: &nullableData{}})
	}
}

func main() {
	addr := flag.String("addr", ":8090", "listen address")
	initHeight := flag.Uint64("init-height", 1000, "initial block height")
	errorRate := flag.Float64("error-rate", 0, "probability [0.0, 1.0] of returning an error response")
	maxDelay := flag.Duration("delay", time.Second, "maximum random response delay (actual delay is random in [0, delay])")
	flag.Parse()

	if *errorRate < 0 || *errorRate > 1 {
		log.Fatalf("--error-rate must be in [0.0, 1.0], got %f", *errorRate)
	}

	s := &server{height: *initHeight, errorRate: *errorRate, maxDelay: *maxDelay}
	go s.tick()

	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chain/confirmed_block_info", s.handleConfirmedBlockInfo)

	fmt.Printf("mock TeeRollup server listening on %s\n", *addr)
	fmt.Printf("initial height: %d\n", *initHeight)
	fmt.Printf("error rate:     %.1f%%\n", *errorRate*100)
	fmt.Printf("max delay:      %s\n", *maxDelay)
	fmt.Println("endpoint: GET /v1/chain/confirmed_block_info")
	fmt.Println()

	if err := http.ListenAndServe(*addr, mux); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
