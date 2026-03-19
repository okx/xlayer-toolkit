package main

import (
	"bytes"
	"encoding/json"
	"io"
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
	resp, err := http.Post(serverURL+"/v1/task/", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("POST /v1/task/ failed: %v", err)
	}
	defer resp.Body.Close()

	var r response
	json.NewDecoder(resp.Body).Decode(&r)
	if r.Code != 0 {
		t.Fatalf("POST /v1/task/ returned code %d: %s", r.Code, r.Message)
	}
	data := r.Data.(map[string]interface{})
	return data["taskId"].(string)
}

func getTask(t *testing.T, serverURL, taskID string) map[string]interface{} {
	t.Helper()
	resp, err := http.Get(serverURL + "/v1/task/" + taskID)
	if err != nil {
		t.Fatalf("GET /v1/task/%s failed: %v", taskID, err)
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
	if data["task_status"] != "Running" {
		t.Errorf("expected Running, got %s", data["task_status"])
	}

	// Wait for task delay to elapse
	time.Sleep(200 * time.Millisecond)

	// Should be Finished now
	data = getTask(t, server.URL, taskID)
	if data["task_status"] != "Finished" {
		t.Errorf("expected Finished, got %s", data["task_status"])
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
	if data["task_status"] != "Failed" {
		t.Errorf("expected Failed, got %s", data["task_status"])
	}

	// Next task should succeed (fail-next is one-shot)
	taskID2 := postTask(t, server.URL, req)
	time.Sleep(200 * time.Millisecond)
	data2 := getTask(t, server.URL, taskID2)
	if data2["task_status"] != "Finished" {
		t.Errorf("expected Finished for second task, got %s", data2["task_status"])
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
	if data["task_status"] != "Running" {
		t.Errorf("expected Running (never-finish), got %s", data["task_status"])
	}

	// Reset and verify new tasks finish normally
	http.Post(server.URL+"/admin/reset", "", nil)
	taskID2 := postTask(t, server.URL, req)
	time.Sleep(200 * time.Millisecond)
	data2 := getTask(t, server.URL, taskID2)
	if data2["task_status"] != "Finished" {
		t.Errorf("expected Finished after reset, got %s", data2["task_status"])
	}
}

func TestDeleteTask(t *testing.T) {
	_, server := setupTestServer(t)

	req := ProveRequest{
		StartBlkHeight:    1,
		EndBlkHeight:      2,
		StartBlkHash:      "0x0000000000000000000000000000000000000000000000000000000000000001",
		EndBlkHash:        "0x0000000000000000000000000000000000000000000000000000000000000002",
		StartBlkStateHash: "0x0000000000000000000000000000000000000000000000000000000000000003",
		EndBlkStateHash:   "0x0000000000000000000000000000000000000000000000000000000000000004",
	}

	taskID := postTask(t, server.URL, req)

	// Delete
	delReq, _ := http.NewRequest(http.MethodDelete, server.URL+"/v1/task/"+taskID, nil)
	resp, err := http.DefaultClient.Do(delReq)
	if err != nil {
		t.Fatalf("DELETE failed: %v", err)
	}
	defer resp.Body.Close()

	var r response
	json.NewDecoder(resp.Body).Decode(&r)
	if r.Code != 0 {
		t.Errorf("expected code 0, got %d", r.Code)
	}

	// GET should return 10004
	getResp, _ := http.Get(server.URL + "/v1/task/" + taskID)
	defer getResp.Body.Close()
	body, _ := io.ReadAll(getResp.Body)
	var gr response
	json.Unmarshal(body, &gr)
	if gr.Code != 10004 {
		t.Errorf("expected code 10004 for deleted task, got %d", gr.Code)
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

	resp, _ := http.Get(server.URL + "/v1/task/nonexistent-id")
	defer resp.Body.Close()

	var r response
	json.NewDecoder(resp.Body).Decode(&r)
	if r.Code != 10004 {
		t.Errorf("expected code 10004, got %d", r.Code)
	}
}
