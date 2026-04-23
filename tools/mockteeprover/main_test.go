package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/crypto"
)

func setupTestServer(t *testing.T) (*MockTEEProver, *httptest.Server) {
	t.Helper()
	key, err := crypto.GenerateKey()
	if err != nil {
		t.Fatalf("failed to generate key: %v", err)
	}
	prover := NewMockTEEProver(key, 100*time.Millisecond)
	server := httptest.NewServer(prover)
	t.Cleanup(server.Close)
	return prover, server
}

func postTask(t *testing.T, serverURL string, req ProveRequest) string {
	t.Helper()
	body, _ := json.Marshal(req)
	resp, err := http.Post(serverURL+"/task/", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("POST /task/ failed: %v", err)
	}
	defer resp.Body.Close()

	var r response
	json.NewDecoder(resp.Body).Decode(&r)
	if r.Code != 0 {
		t.Fatalf("POST /task/ returned code %d: %s", r.Code, r.Message)
	}
	data := r.Data.(map[string]interface{})
	return data["taskId"].(string)
}

func getTask(t *testing.T, serverURL, taskID string) map[string]interface{} {
	t.Helper()
	resp, err := http.Get(serverURL + "/task/" + taskID)
	if err != nil {
		t.Fatalf("GET /task/%s failed: %v", taskID, err)
	}
	defer resp.Body.Close()

	var r response
	json.NewDecoder(resp.Body).Decode(&r)
	return r.Data.(map[string]interface{})
}

func TestHealthEndpoint(t *testing.T) {
	_, server := setupTestServer(t)

	resp, err := http.Get(server.URL + "/health")
	if err != nil {
		t.Fatalf("GET /health failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		t.Errorf("expected 200, got %d", resp.StatusCode)
	}
}

func TestCreateAndPollTask(t *testing.T) {
	_, server := setupTestServer(t)

	req := ProveRequest{
		StartBlkHeight:    100,
		EndBlkHeight:      200,
		StartBlkHash:      "0x0000000000000000000000000000000000000000000000000000000000000001",
		EndBlkHash:        "0x0000000000000000000000000000000000000000000000000000000000000002",
		StartBlkStateHash: "0x0000000000000000000000000000000000000000000000000000000000000003",
		EndBlkStateHash:   "0x0000000000000000000000000000000000000000000000000000000000000004",
	}

	taskID := postTask(t, server.URL, req)
	if taskID == "" {
		t.Fatal("got empty taskId")
	}

	// Immediately should be Running
	data := getTask(t, server.URL, taskID)
	if data["status"] != "Running" {
		t.Errorf("expected Running, got %s", data["status"])
	}

	// Wait for task delay to elapse
	time.Sleep(200 * time.Millisecond)

	// Should be Finished now
	data = getTask(t, server.URL, taskID)
	if data["status"] != "Finished" {
		t.Errorf("expected Finished, got %s", data["status"])
	}
	if data["proofBytes"] == nil || data["proofBytes"] == "" {
		t.Error("expected proofBytes to be set")
	}
}

func TestFailNext(t *testing.T) {
	_, server := setupTestServer(t)

	// Enable fail-next
	http.Post(server.URL+"/admin/fail-next", "", nil)

	req := ProveRequest{
		StartBlkHeight:    1,
		EndBlkHeight:      2,
		StartBlkHash:      "0x0000000000000000000000000000000000000000000000000000000000000001",
		EndBlkHash:        "0x0000000000000000000000000000000000000000000000000000000000000002",
		StartBlkStateHash: "0x0000000000000000000000000000000000000000000000000000000000000003",
		EndBlkStateHash:   "0x0000000000000000000000000000000000000000000000000000000000000004",
	}

	taskID := postTask(t, server.URL, req)
	data := getTask(t, server.URL, taskID)
	if data["status"] != "Failed" {
		t.Errorf("expected Failed, got %s", data["status"])
	}

	// Next task should succeed (fail-next is one-shot)
	taskID2 := postTask(t, server.URL, req)
	time.Sleep(200 * time.Millisecond)
	data2 := getTask(t, server.URL, taskID2)
	if data2["status"] != "Finished" {
		t.Errorf("expected Finished for second task, got %s", data2["status"])
	}
}

func TestNeverFinish(t *testing.T) {
	_, server := setupTestServer(t)

	http.Post(server.URL+"/admin/never-finish", "", nil)

	req := ProveRequest{
		StartBlkHeight:    1,
		EndBlkHeight:      2,
		StartBlkHash:      "0x0000000000000000000000000000000000000000000000000000000000000001",
		EndBlkHash:        "0x0000000000000000000000000000000000000000000000000000000000000002",
		StartBlkStateHash: "0x0000000000000000000000000000000000000000000000000000000000000003",
		EndBlkStateHash:   "0x0000000000000000000000000000000000000000000000000000000000000004",
	}

	taskID := postTask(t, server.URL, req)
	time.Sleep(200 * time.Millisecond)

	data := getTask(t, server.URL, taskID)
	if data["status"] != "Running" {
		t.Errorf("expected Running (never-finish), got %s", data["status"])
	}

	// Reset and verify new tasks finish normally
	http.Post(server.URL+"/admin/reset", "", nil)
	taskID2 := postTask(t, server.URL, req)
	time.Sleep(200 * time.Millisecond)
	data2 := getTask(t, server.URL, taskID2)
	if data2["status"] != "Finished" {
		t.Errorf("expected Finished after reset, got %s", data2["status"])
	}
}

func TestStats(t *testing.T) {
	_, server := setupTestServer(t)

	req := ProveRequest{
		StartBlkHeight:    10,
		EndBlkHeight:      20,
		StartBlkHash:      "0x0000000000000000000000000000000000000000000000000000000000000001",
		EndBlkHash:        "0x0000000000000000000000000000000000000000000000000000000000000002",
		StartBlkStateHash: "0x0000000000000000000000000000000000000000000000000000000000000003",
		EndBlkStateHash:   "0x0000000000000000000000000000000000000000000000000000000000000004",
	}

	postTask(t, server.URL, req)
	postTask(t, server.URL, req)

	resp, _ := http.Get(server.URL + "/admin/stats")
	defer resp.Body.Close()

	var stats map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&stats)

	count := int(stats["task_count"].(float64))
	if count != 2 {
		t.Errorf("expected 2 tasks in stats, got %d", count)
	}
}

func TestTaskNotFound(t *testing.T) {
	_, server := setupTestServer(t)

	resp, _ := http.Get(server.URL + "/task/nonexistent-id")
	defer resp.Body.Close()

	var r response
	json.NewDecoder(resp.Body).Decode(&r)
	if r.Code != 10004 {
		t.Errorf("expected code 10004, got %d", r.Code)
	}
}
