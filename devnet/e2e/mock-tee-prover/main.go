package main

import (
	"crypto/ecdsa"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/google/uuid"
)

// ProveRequest matches op-challenger/game/tee/prover_client.go ProveRequest.
type ProveRequest struct {
	StartBlkHeight    uint64 `json:"startBlkHeight"`
	EndBlkHeight      uint64 `json:"endBlkHeight"`
	StartBlkHash      string `json:"startBlkHash"`
	EndBlkHash        string `json:"endBlkHash"`
	StartBlkStateHash string `json:"startBlkStateHash"`
	EndBlkStateHash   string `json:"endBlkStateHash"`
}

type task struct {
	ID         string
	Status     string // "Running", "Finished", "Failed"
	CreatedAt  time.Time
	FinishAt   time.Time // when the task should transition to Finished
	Request    ProveRequest
	ProofBytes []byte // set when Finished
	FailCode   int    // error code when Failed
}

type response struct {
	Code    int         `json:"code"`
	Message string      `json:"message"`
	Data    interface{} `json:"data"`
}

type MockTEEProver struct {
	mu        sync.Mutex
	tasks     map[string]*task
	signerKey *ecdsa.PrivateKey
	taskDelay time.Duration

	// control flags
	failNext    bool
	neverFinish bool

	// stats
	submittedRequests []ProveRequest
}

func NewMockTEEProver(signerKey *ecdsa.PrivateKey, taskDelay time.Duration) *MockTEEProver {
	return &MockTEEProver{
		tasks:     make(map[string]*task),
		signerKey: signerKey,
		taskDelay: taskDelay,
	}
}

// POST /v1/task/
func (m *MockTEEProver) handleCreateTask(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, response{Code: -1, Message: "method not allowed"})
		return
	}

	var req ProveRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, response{Code: 10001, Message: fmt.Sprintf("invalid request: %v", err)})
		return
	}

	m.mu.Lock()
	m.submittedRequests = append(m.submittedRequests, req)

	id := uuid.New().String()
	t := &task{
		ID:        id,
		Status:    "Running",
		CreatedAt: time.Now(),
		FinishAt:  time.Now().Add(m.taskDelay),
		Request:   req,
	}

	if m.failNext {
		t.Status = "Failed"
		t.FailCode = 10000 // retryable
		m.failNext = false
	} else if m.neverFinish {
		// stays Running forever
		t.FinishAt = time.Now().Add(24 * time.Hour)
	}

	m.tasks[id] = t
	m.mu.Unlock()

	log.Printf("[POST /v1/task/] created task %s for blocks %d→%d (status=%s)", id, req.StartBlkHeight, req.EndBlkHeight, t.Status)

	writeJSON(w, response{
		Code:    0,
		Message: "ok",
		Data:    map[string]string{"taskId": id},
	})
}

// GET /v1/task/{taskId}
func (m *MockTEEProver) handleGetTask(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, response{Code: -1, Message: "method not allowed"})
		return
	}

	taskID := extractTaskID(r.URL.Path)
	if taskID == "" {
		writeJSON(w, response{Code: 10004, Message: "task not found"})
		return
	}

	m.mu.Lock()
	t, ok := m.tasks[taskID]
	if !ok {
		m.mu.Unlock()
		writeJSON(w, response{Code: 10004, Message: "task not found"})
		return
	}

	// Transition Running → Finished if delay has elapsed
	if t.Status == "Running" && time.Now().After(t.FinishAt) {
		proofBytes, err := generateProofBytes(t.Request, m.signerKey)
		if err != nil {
			log.Printf("[GET /v1/task/%s] ERROR generating proof: %v", taskID, err)
			t.Status = "Failed"
			t.FailCode = 20001
		} else {
			t.Status = "Finished"
			t.ProofBytes = proofBytes
		}
	}

	// Build response data
	data := map[string]interface{}{
		"task_id":     t.ID,
		"task_status": t.Status,
	}
	if t.Status == "Finished" {
		data["proofBytes"] = hexutil.Encode(t.ProofBytes)
	}
	if t.Status == "Failed" {
		data["detail"] = fmt.Sprintf("mock failure (code=%d)", t.FailCode)
	}
	m.mu.Unlock()

	log.Printf("[GET /v1/task/%s] status=%s", taskID, t.Status)

	writeJSON(w, response{Code: 0, Message: "ok", Data: data})
}

// DELETE /v1/task/{taskId}
func (m *MockTEEProver) handleDeleteTask(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		writeJSON(w, response{Code: -1, Message: "method not allowed"})
		return
	}

	taskID := extractTaskID(r.URL.Path)

	m.mu.Lock()
	_, ok := m.tasks[taskID]
	if ok {
		delete(m.tasks, taskID)
	}
	m.mu.Unlock()

	if !ok {
		writeJSON(w, response{Code: 10001, Message: "task not found"})
		return
	}

	log.Printf("[DELETE /v1/task/%s] deleted", taskID)
	writeJSON(w, response{Code: 0, Message: "ok"})
}

// POST /admin/fail-next
func (m *MockTEEProver) handleFailNext(w http.ResponseWriter, r *http.Request) {
	m.mu.Lock()
	m.failNext = true
	m.mu.Unlock()
	log.Println("[admin] fail-next enabled")
	writeJSON(w, response{Code: 0, Message: "fail-next enabled"})
}

// POST /admin/never-finish
func (m *MockTEEProver) handleNeverFinish(w http.ResponseWriter, r *http.Request) {
	m.mu.Lock()
	m.neverFinish = true
	m.mu.Unlock()
	log.Println("[admin] never-finish enabled")
	writeJSON(w, response{Code: 0, Message: "never-finish enabled"})
}

// POST /admin/reset
func (m *MockTEEProver) handleReset(w http.ResponseWriter, r *http.Request) {
	m.mu.Lock()
	m.failNext = false
	m.neverFinish = false
	m.mu.Unlock()
	log.Println("[admin] reset all control flags")
	writeJSON(w, response{Code: 0, Message: "reset"})
}

// GET /admin/stats
func (m *MockTEEProver) handleStats(w http.ResponseWriter, r *http.Request) {
	m.mu.Lock()
	stats := map[string]interface{}{
		"task_count":      len(m.submittedRequests),
		"requests":        m.submittedRequests,
		"fail_next":       m.failNext,
		"never_finish":    m.neverFinish,
		"active_tasks":    len(m.tasks),
	}
	m.mu.Unlock()
	writeJSON(w, stats)
}

// GET /health
func (m *MockTEEProver) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]string{"status": "ok"})
}

func (m *MockTEEProver) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path

	switch {
	case path == "/health":
		m.handleHealth(w, r)
	case path == "/v1/task/" && r.Method == http.MethodPost:
		m.handleCreateTask(w, r)
	case strings.HasPrefix(path, "/v1/task/") && r.Method == http.MethodGet:
		m.handleGetTask(w, r)
	case strings.HasPrefix(path, "/v1/task/") && r.Method == http.MethodDelete:
		m.handleDeleteTask(w, r)
	case path == "/admin/fail-next":
		m.handleFailNext(w, r)
	case path == "/admin/never-finish":
		m.handleNeverFinish(w, r)
	case path == "/admin/reset":
		m.handleReset(w, r)
	case path == "/admin/stats":
		m.handleStats(w, r)
	default:
		http.NotFound(w, r)
	}
}

func extractTaskID(path string) string {
	// /v1/task/{taskId} or /v1/task/{taskId}/
	path = strings.TrimPrefix(path, "/v1/task/")
	path = strings.TrimSuffix(path, "/")
	if path == "" {
		return ""
	}
	return path
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("ERROR writing JSON response: %v", err)
	}
}

func main() {
	signerKeyHex := os.Getenv("SIGNER_PRIVATE_KEY")
	if signerKeyHex == "" {
		log.Fatal("SIGNER_PRIVATE_KEY environment variable is required")
	}
	signerKeyHex = strings.TrimPrefix(signerKeyHex, "0x")

	signerKey, err := crypto.HexToECDSA(signerKeyHex)
	if err != nil {
		log.Fatalf("invalid SIGNER_PRIVATE_KEY: %v", err)
	}

	signerAddr := crypto.PubkeyToAddress(signerKey.PublicKey)
	log.Printf("Mock TEE Prover starting, signer address: %s", signerAddr.Hex())

	listenAddr := os.Getenv("LISTEN_ADDR")
	if listenAddr == "" {
		listenAddr = ":8690"
	}

	taskDelay := 2 * time.Second
	if d := os.Getenv("TASK_DELAY"); d != "" {
		parsed, err := time.ParseDuration(d)
		if err != nil {
			log.Fatalf("invalid TASK_DELAY: %v", err)
		}
		taskDelay = parsed
	}

	prover := NewMockTEEProver(signerKey, taskDelay)

	log.Printf("Listening on %s (task_delay=%s)", listenAddr, taskDelay)
	if err := http.ListenAndServe(listenAddr, prover); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
