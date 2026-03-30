package mockteerpc

import (
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"log"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/crypto"
)

// TeeRollupResponse is the normal JSON shape returned by GET /chain/confirmed_block_info.
type TeeRollupResponse struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    struct {
		Height    uint64 `json:"height"`
		AppHash   string `json:"appHash"`
		BlockHash string `json:"blockHash"`
	} `json:"data"`
}

// Option configures a TeeRollupServer.
type Option func(*TeeRollupServer)

// WithErrorRate sets the probability [0.0, 1.0] that any given RPC call returns an error.
// Three error types are equally likely when an error occurs:
//  1. code != 0, no data field, only message.
//  2. code == 0, data is null.
//  3. code == 0, data is present but all fields (height, appHash, blockHash) are null.
func WithErrorRate(rate float64) Option {
	return func(s *TeeRollupServer) {
		s.errorRate = rate
	}
}

// WithMaxDelay sets the maximum random response delay. Each request sleeps for a
// random duration in [0, maxDelay]. Default is 1s.
func WithMaxDelay(d time.Duration) Option {
	return func(s *TeeRollupServer) {
		s.maxDelay = d
	}
}

// TeeRollupServer is a mock TeeRollup HTTP server for testing.
// Height starts at 1000 and increments by a random value in [1, 50] every second.
type TeeRollupServer struct {
	server    *httptest.Server
	mu        sync.RWMutex
	height    uint64
	errorRate float64
	maxDelay  time.Duration
	stopCh    chan struct{}
	doneCh    chan struct{}
	closeOnce sync.Once
}

// NewTeeRollupServer starts the mock server and its background tick goroutine.
// Close() is registered via t.Cleanup so callers need not call it explicitly.
func NewTeeRollupServer(t *testing.T, opts ...Option) *TeeRollupServer {
	t.Helper()

	m := &TeeRollupServer{
		height:   1000,
		maxDelay: time.Second,
		stopCh:   make(chan struct{}),
		doneCh:   make(chan struct{}),
	}
	for _, opt := range opts {
		opt(m)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/chain/confirmed_block_info", m.handleConfirmedBlockInfo)

	m.server = httptest.NewServer(mux)

	go m.tick()

	t.Cleanup(m.Close)
	return m
}

// Addr returns the base URL (scheme + host) of the test server.
func (m *TeeRollupServer) Addr() string {
	return m.server.URL
}

// Close stops the tick goroutine and shuts down the HTTP server.
// Safe to call multiple times.
func (m *TeeRollupServer) Close() {
	m.closeOnce.Do(func() {
		close(m.stopCh)
		<-m.doneCh
		m.server.Close()
	})
}

// CurrentInfo returns the current height, appHash and blockHash snapshot.
// Useful for assertions in tests without making an HTTP round-trip.
func (m *TeeRollupServer) CurrentInfo() (height uint64, appHash, blockHash [32]byte) {
	m.mu.RLock()
	h := m.height
	m.mu.RUnlock()

	appHash = ComputeAppHash(h)
	blockHash = ComputeBlockHash(appHash)
	return h, appHash, blockHash
}

// tick increments height by random(1, 50) every second until Close() is called.
func (m *TeeRollupServer) tick() {
	defer close(m.doneCh)

	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-m.stopCh:
			return
		case <-ticker.C:
			delta := uint64(rand.Intn(50) + 1) // [1, 50]
			m.mu.Lock()
			m.height += delta
			m.mu.Unlock()
		}
	}
}

// handleConfirmedBlockInfo serves GET /chain/confirmed_block_info.
func (m *TeeRollupServer) handleConfirmedBlockInfo(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	log.Printf("[mockteerpc] received %s %s from %s", r.Method, r.URL.Path, r.RemoteAddr)

	// Random delay in [0, maxDelay].
	if m.maxDelay > 0 {
		delay := time.Duration(rand.Int63n(int64(m.maxDelay) + 1))
		time.Sleep(delay)
	}

	w.Header().Set("Content-Type", "application/json")

	// Inject error according to configured error rate.
	if m.errorRate > 0 && rand.Float64() < m.errorRate {
		writeErrorResponse(w)
		log.Printf("[mockteerpc] responded with error (took %s)", time.Since(start))
		return
	}

	m.mu.RLock()
	h := m.height
	m.mu.RUnlock()

	appHash := ComputeAppHash(h)
	blockHash := ComputeBlockHash(appHash)

	resp := TeeRollupResponse{Code: 0, Message: "OK"}
	resp.Data.Height = h
	resp.Data.AppHash = "0x" + hex.EncodeToString(appHash[:])
	resp.Data.BlockHash = "0x" + hex.EncodeToString(blockHash[:])

	_ = json.NewEncoder(w).Encode(resp)
	log.Printf("[mockteerpc] responded height=%d appHash=%s (took %s)", h, resp.Data.AppHash[:10]+"...", time.Since(start))
}

// writeErrorResponse writes one of three error shapes, chosen at random.
//
//	Type 0: code != 0, no data field.
//	Type 1: code == 0, data is null.
//	Type 2: code == 0, data present but all fields are null.
func writeErrorResponse(w http.ResponseWriter) {
	type nullableFields struct {
		Height    *uint64 `json:"height"`
		AppHash   *string `json:"appHash"`
		BlockHash *string `json:"blockHash"`
	}
	// type 0: no data field
	type respNoData struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	}
	// type 1 & 2: has data field (null or with null fields)
	type respWithData struct {
		Code    int             `json:"code"`
		Message string          `json:"message"`
		Data    *nullableFields `json:"data"`
	}

	switch rand.Intn(3) {
	case 0: // code != 0, no data field
		_ = json.NewEncoder(w).Encode(respNoData{
			Code:    1,
			Message: "internal server error",
		})
	case 1: // code == 0, data is null
		_ = json.NewEncoder(w).Encode(respWithData{
			Code:    0,
			Message: "OK",
			Data:    nil,
		})
	case 2: // code == 0, data present but all fields are null
		_ = json.NewEncoder(w).Encode(respWithData{
			Code:    0,
			Message: "OK",
			Data:    &nullableFields{}, // all pointer fields are nil → JSON null
		})
	}
}

// ComputeAppHash returns keccak256(big-endian uint64 bytes of height).
func ComputeAppHash(height uint64) [32]byte {
	var buf [8]byte
	binary.BigEndian.PutUint64(buf[:], height)
	return crypto.Keccak256Hash(buf[:])
}

// ComputeBlockHash returns keccak256(appHash[:]).
func ComputeBlockHash(appHash [32]byte) [32]byte {
	return crypto.Keccak256Hash(appHash[:])
}
