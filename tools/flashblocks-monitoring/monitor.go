package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// ──────────────────────────────────────────────
// JSON-RPC types for eth_subscribe flashblocks
// ──────────────────────────────────────────────

type WSSubscribeRequest struct {
	JSONRPC string `json:"jsonrpc"`
	ID      int    `json:"id"`
	Method  string `json:"method"`
	Params  []any  `json:"params"`
}

type WSSubscribeResponse struct {
	JSONRPC string `json:"jsonrpc"`
	ID      int    `json:"id"`
	Result  string `json:"result"`
	Error   *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

type WSNotification struct {
	JSONRPC string `json:"jsonrpc"`
	Method  string `json:"method"`
	Params  struct {
		Subscription string          `json:"subscription"`
		Result       json.RawMessage `json:"result"`
	} `json:"params"`
}

type FlashblockEvent struct {
	Type        string             `json:"type"`
	Header      *FlashblockHeader  `json:"header,omitempty"`
	Transaction *FlashblockTxEvent `json:"transaction,omitempty"`
}

type FlashblockHeader struct {
	Hash       string `json:"hash"`
	ParentHash string `json:"parentHash"`
	Number     string `json:"number"`
	Timestamp  string `json:"timestamp"`
	GasUsed    string `json:"gasUsed"`
}

type FlashblockTxEvent struct {
	TxHash  string            `json:"txHash"`
	TxData  FlashblockTxData  `json:"txData"`
	Receipt FlashblockReceipt `json:"receipt"`
}

type FlashblockTxData struct {
	Type        string `json:"type"`
	From        string `json:"from"`
	To          string `json:"to"`
	BlockNumber string `json:"blockNumber"`
	BlockHash   string `json:"blockHash"`
}

type FlashblockReceipt struct {
	Type            string `json:"type"`
	Status          string `json:"status"`
	TransactionHash string `json:"transactionHash"`
	BlockNumber     string `json:"blockNumber"`
	BlockHash       string `json:"blockHash"`
}

// ──────────────────────────────────────────────
// txBatch: per-block tx collector for Alert 2
// ──────────────────────────────────────────────

type txBatch struct {
	mu       sync.Mutex
	txHashes []string
	timer    *time.Timer // fallback timeout timer
}

// blockContext holds the current pending block info from flashblocks.
type blockContext struct {
	blockNum  int64
	timestamp int64
	hash      string
}

// ──────────────────────────────────────────────
// Monitor
// ──────────────────────────────────────────────

type Monitor struct {
	cfg     *Config
	alerter *Alerter

	ctxMu  sync.Mutex
	curCtx blockContext

	// Alert 2: per-block pending tx batches, blockNumber -> *txBatch
	pendingTxs sync.Map

	rpcClient *http.Client

	stats Stats
}

type Stats struct {
	mu                  sync.Mutex
	FlashblocksReceived int64
	TxsTracked          int64
	TxsConfirmed        int64
	TxsMissing          int64
	LatencyAlerts       int64
	Reconnections       int64
}

func (s *Stats) inc(field *int64) {
	s.mu.Lock()
	*field++
	s.mu.Unlock()
}

func (s *Stats) add(field *int64, n int64) {
	s.mu.Lock()
	*field += n
	s.mu.Unlock()
}

func NewMonitor(cfg *Config) *Monitor {
	return &Monitor{
		cfg:     cfg,
		alerter: NewAlerter(cfg.AlertEnabled, cfg.LarkBotURL, cfg.LarkGroupID, cfg.AlertRateLimit),
		rpcClient: &http.Client{
			Timeout: cfg.RPCTimeout,
		},
	}
}

// ──────────────────────────────────────────────
// WebSocket listener (JSON-RPC eth_subscribe)
// ──────────────────────────────────────────────

func (m *Monitor) RunWSListener() {
	if m.cfg.WSURL == "" {
		log.Printf("[WS] WS_URL not configured, WebSocket listener disabled")
		return
	}

	reconnectDelay := time.Second
	maxReconnectDelay := 30 * time.Second
	consecutiveFails := 0
	firstFailTime := time.Time{}

	for {
		connectedAt := time.Now()

		// Clear pendingTxs on reconnect — data is incomplete during disconnect, avoid false positives
		m.clearPendingTxs()

		err := m.connectAndListen()
		if err != nil {
			m.stats.inc(&m.stats.Reconnections)
			consecutiveFails++
			if consecutiveFails == 1 {
				firstFailTime = time.Now()
			}
			log.Printf("[WS] Disconnected: %v, reconnecting in %v... (consecutive fails: %d)",
				err, reconnectDelay, consecutiveFails)

			m.alerter.Send(AlertWSDown, "WebSocket disconnected",
				fmt.Sprintf("URL: %s\nError: %v", m.cfg.WSURL, err))

			if consecutiveFails >= 3 && time.Since(firstFailTime) > m.cfg.WSLongDownThreshold {
				m.alerter.Send(AlertWSLongDown,
					fmt.Sprintf("WebSocket unavailable for %v", time.Since(firstFailTime).Round(time.Second)),
					fmt.Sprintf("URL: %s\nConsecutive failures: %d\nFirst failure: %s\nLast error: %v",
						m.cfg.WSURL, consecutiveFails,
						firstFailTime.Format("2006-01-02 15:04:05"), err))
			}
		}
		if time.Since(connectedAt) > 30*time.Second {
			reconnectDelay = time.Second
			consecutiveFails = 0
			firstFailTime = time.Time{}
		}
		time.Sleep(reconnectDelay)
		reconnectDelay = min(reconnectDelay*2, maxReconnectDelay)
	}
}

// clearPendingTxs clears all pending tx batches and stops their fallback timers
func (m *Monitor) clearPendingTxs() {
	m.pendingTxs.Range(func(key, value any) bool {
		batch := value.(*txBatch)
		batch.mu.Lock()
		if batch.timer != nil {
			batch.timer.Stop()
		}
		batch.mu.Unlock()
		m.pendingTxs.Delete(key)
		return true
	})
}

func (m *Monitor) connectAndListen() error {
	log.Printf("[WS] Connecting to %s ...", m.cfg.WSURL)

	dialer := websocket.Dialer{HandshakeTimeout: 10 * time.Second}
	conn, _, err := dialer.Dial(m.cfg.WSURL, nil)
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}
	defer conn.Close()

	log.Printf("[WS] Connected to %s", m.cfg.WSURL)
	conn.SetReadLimit(10 * 1024 * 1024)

	// ── Send eth_subscribe request ──
	subReq := WSSubscribeRequest{
		JSONRPC: "2.0",
		ID:      1,
		Method:  "eth_subscribe",
		Params: []any{
			"flashblocks",
			map[string]any{
				"headerInfo": true,
				"subTxFilter": map[string]any{
					"txInfo":    true,
					"txReceipt": true,
				},
			},
		},
	}
	if err := conn.WriteJSON(subReq); err != nil {
		return fmt.Errorf("send subscribe: %w", err)
	}
	log.Printf("[WS] Sent eth_subscribe request")

	// ── Wait for subscription confirmation ──
	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	_, subMsg, err := conn.ReadMessage()
	if err != nil {
		m.alerter.Send(AlertSubscribeFail, "Flashblocks subscribe failed",
			fmt.Sprintf("URL: %s\nError: timeout or read error: %v", m.cfg.WSURL, err))
		return fmt.Errorf("read subscribe response: %w", err)
	}

	var subResp WSSubscribeResponse
	if err := json.Unmarshal(subMsg, &subResp); err != nil {
		m.alerter.Send(AlertSubscribeFail, "Flashblocks subscribe failed",
			fmt.Sprintf("URL: %s\nError: invalid response: %v\nRaw: %s", m.cfg.WSURL, err, string(subMsg)))
		return fmt.Errorf("parse subscribe response: %w", err)
	}
	if subResp.Error != nil {
		m.alerter.Send(AlertSubscribeFail, "Flashblocks subscribe failed",
			fmt.Sprintf("URL: %s\nRPC Error: [%d] %s", m.cfg.WSURL, subResp.Error.Code, subResp.Error.Message))
		return fmt.Errorf("subscribe error %d: %s", subResp.Error.Code, subResp.Error.Message)
	}
	if subResp.Result == "" {
		m.alerter.Send(AlertSubscribeFail, "Flashblocks subscribe failed",
			fmt.Sprintf("URL: %s\nError: empty subscription ID\nRaw: %s", m.cfg.WSURL, string(subMsg)))
		return fmt.Errorf("subscribe returned empty subscription ID")
	}

	log.Printf("[WS] Subscribed successfully, subscription ID: %s", subResp.Result)

	conn.SetReadDeadline(time.Time{})

	for {
		_, message, err := conn.ReadMessage()
		if err != nil {
			return fmt.Errorf("read: %w", err)
		}
		m.handleMessage(message)
	}
}

func (m *Monitor) handleMessage(raw []byte) {
	var notif WSNotification
	if err := json.Unmarshal(raw, &notif); err != nil {
		if m.cfg.Verbose {
			log.Printf("[WS] Failed to parse notification: %v", err)
		}
		return
	}

	if notif.Method != "eth_subscription" {
		if m.cfg.Verbose {
			log.Printf("[WS] Ignoring non-subscription message: method=%s", notif.Method)
		}
		return
	}

	var event FlashblockEvent
	if err := json.Unmarshal(notif.Params.Result, &event); err != nil {
		if m.cfg.Verbose {
			log.Printf("[WS] Failed to parse event result: %v", err)
		}
		return
	}

	m.stats.inc(&m.stats.FlashblocksReceived)

	switch event.Type {
	case "header":
		m.handleHeader(event.Header)
	case "transaction":
		m.handleTransaction(event.Transaction)
	default:
		if m.cfg.Verbose {
			log.Printf("[WS] Unknown event type: %s", event.Type)
		}
	}
}

// ──────────────────────────────────────────────
// Header handler: update context + trigger prev block verification
// ──────────────────────────────────────────────

func (m *Monitor) handleHeader(header *FlashblockHeader) {
	if header == nil {
		return
	}

	blockNum := hexToInt64(header.Number)
	ts := hexToInt64(header.Timestamp)

	m.ctxMu.Lock()
	prevBlockNum := m.curCtx.blockNum
	isNewBlock := prevBlockNum != blockNum
	m.curCtx = blockContext{
		blockNum:  blockNum,
		timestamp: ts,
		hash:      header.Hash,
	}
	m.ctxMu.Unlock()

	if !isNewBlock {
		return
	}

	if m.cfg.Verbose {
		log.Printf("[WS] New block #%d (ts: %d, hash: %s...)", blockNum, ts, truncate(header.Hash, 16))
	}

	// New block arrived, trigger batch verification for the previous block
	if prevBlockNum > 0 {
		m.triggerVerify(prevBlockNum)
	}
}

// ──────────────────────────────────────────────
// Transaction handler: Alert 1 (immediate) + collect for Alert 2
// ──────────────────────────────────────────────

func (m *Monitor) handleTransaction(tx *FlashblockTxEvent) {
	if tx == nil {
		return
	}

	now := time.Now()

	// Skip deposit tx (type 0x7e)
	if tx.TxData.Type == "0x7e" {
		if m.cfg.Verbose {
			log.Printf("[WS] Skipping deposit tx: %s", tx.TxHash)
		}
		return
	}

	blockNum := hexToInt64(tx.TxData.BlockNumber)
	if blockNum == 0 {
		m.ctxMu.Lock()
		blockNum = m.curCtx.blockNum
		m.ctxMu.Unlock()
	}
	if blockNum == 0 {
		if m.cfg.Verbose {
			log.Printf("[WS] Transaction %s but no block context, skipping", tx.TxHash)
		}
		return
	}

	m.ctxMu.Lock()
	blockTS := m.curCtx.timestamp
	m.ctxMu.Unlock()

	m.stats.inc(&m.stats.TxsTracked)

	log.Printf("[WS] Block #%d: tx %s (type: %s, from: %s)",
		blockNum, tx.TxHash, tx.TxData.Type, truncate(tx.TxData.From, 16))

	// ── Alert 1: latency check (immediate, per-tx) ──
	if blockTS > 0 {
		deadline := time.Unix(blockTS, 0).Add(m.cfg.MaxFlashblockDelay)
		if now.After(deadline) {
			delay := now.Sub(time.Unix(blockTS, 0))
			m.stats.inc(&m.stats.LatencyAlerts)

			blockTime := time.Unix(blockTS, 0).Format("15:04:05")
			details := fmt.Sprintf("Block: #%d\nBlock time: %s\nReceived at: %s\nDelay: %v\nThreshold: %v\nTx: %s\n",
				blockNum, blockTime, now.Format("15:04:05.000"), delay, m.cfg.MaxFlashblockDelay, tx.TxHash)
			m.alerter.Send(AlertLatency,
				fmt.Sprintf("Flashblock latency > %v at block #%d", m.cfg.MaxFlashblockDelay, blockNum),
				details)
		}
	}

	// ── Alert 2: collect tx into batch, verify when new block arrives or on timeout fallback ──
	m.addToBatch(blockNum, tx.TxHash)
}

// ──────────────────────────────────────────────
// Alert 2: batch collection + verification
// ──────────────────────────────────────────────

// addToBatch adds a txHash to the corresponding block's batch, starts a fallback timeout timer on the first tx
func (m *Monitor) addToBatch(blockNum int64, txHash string) {
	val, loaded := m.pendingTxs.LoadOrStore(blockNum, &txBatch{})
	batch := val.(*txBatch)

	batch.mu.Lock()
	batch.txHashes = append(batch.txHashes, txHash)
	// Start fallback timeout timer when the first tx is added
	if !loaded {
		batch.timer = time.AfterFunc(m.cfg.VerifyTimeout, func() {
			log.Printf("[CHECK] Block #%d: verify timeout triggered (%v), forcing verification",
				blockNum, m.cfg.VerifyTimeout)
			m.triggerVerify(blockNum)
		})
	}
	batch.mu.Unlock()
}

// triggerVerify triggers batch verification for a block, extracts the batch and runs in a goroutine
func (m *Monitor) triggerVerify(blockNum int64) {
	val, ok := m.pendingTxs.LoadAndDelete(blockNum)
	if !ok {
		return
	}

	batch := val.(*txBatch)
	batch.mu.Lock()
	if batch.timer != nil {
		batch.timer.Stop()
	}
	txHashes := make([]string, len(batch.txHashes))
	copy(txHashes, batch.txHashes)
	batch.mu.Unlock()

	if len(txHashes) == 0 {
		return
	}

	go m.verifyBatch(blockNum, txHashes)
}

// verifyBatch waits TxCheckDelay, then checks if all txs are in the canonical block.
func (m *Monitor) verifyBatch(blockNum int64, txHashes []string) {
	time.Sleep(m.cfg.TxCheckDelay)

	var block *RPCBlock
	var err error
	blockHex := fmt.Sprintf("0x%x", blockNum)

	for attempt := range 4 {
		block, err = m.rpcGetBlock(blockHex)
		if err == nil {
			break
		}
		if attempt < 3 {
			if m.cfg.Verbose {
				log.Printf("[CHECK] Block #%d not available (attempt %d/4): %v, retrying...", blockNum, attempt+1, err)
			}
			time.Sleep(500 * time.Millisecond)
		}
	}
	if err != nil {
		log.Printf("[CHECK] Block #%d still unavailable after retries: %v, skipping", blockNum, err)
		return
	}

	// Build canonical tx set
	canonicalTxs := make(map[string]bool, len(block.Transactions))
	for _, txHash := range block.Transactions {
		canonicalTxs[strings.ToLower(txHash)] = true
	}

	var missingTxs []string
	for _, txHash := range txHashes {
		if !canonicalTxs[strings.ToLower(txHash)] {
			missingTxs = append(missingTxs, txHash)
		}
	}

	confirmed := len(txHashes) - len(missingTxs)
	m.stats.add(&m.stats.TxsConfirmed, int64(confirmed))

	if len(missingTxs) > 0 {
		m.stats.add(&m.stats.TxsMissing, int64(len(missingTxs)))

		details := fmt.Sprintf("Block: #%d\nChecked after: %v\nConfirmed: %d\nMISSING: %d\n\nMissing tx hashes:\n",
			blockNum, m.cfg.TxCheckDelay, confirmed, len(missingTxs))
		for i, txHash := range missingTxs {
			if i >= 10 {
				details += fmt.Sprintf("  ... and %d more\n", len(missingTxs)-10)
				break
			}
			details += fmt.Sprintf("  %s\n", txHash)
		}
		m.alerter.Send(AlertMissing,
			fmt.Sprintf("Tx missing from block #%d (%d txs)", blockNum, len(missingTxs)),
			details)
		log.Printf("[REORG] Block #%d: %d confirmed, %d MISSING", blockNum, confirmed, len(missingTxs))
	} else if m.cfg.Verbose && confirmed > 0 {
		log.Printf("[OK] Block #%d: all %d txs confirmed", blockNum, confirmed)
	}
}

// ──────────────────────────────────────────────
// RPC helpers
// ──────────────────────────────────────────────

type RPCBlock struct {
	Number       string   `json:"number"`
	Timestamp    string   `json:"timestamp"`
	Hash         string   `json:"hash"`
	Transactions []string `json:"transactions"`
}

func (m *Monitor) rpcGetBlock(blockID string) (*RPCBlock, error) {
	reqBody, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "eth_getBlockByNumber",
		"params":  []any{blockID, false},
	})

	resp, err := m.rpcClient.Post(m.cfg.RPCURL, "application/json", bytes.NewReader(reqBody))
	if err != nil {
		return nil, fmt.Errorf("rpc post: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read body: %w", err)
	}

	var rpcResp struct {
		Result *RPCBlock `json:"result"`
		Error  *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &rpcResp); err != nil {
		return nil, fmt.Errorf("unmarshal: %w", err)
	}
	if rpcResp.Error != nil {
		return nil, fmt.Errorf("rpc error %d: %s", rpcResp.Error.Code, rpcResp.Error.Message)
	}
	if rpcResp.Result == nil {
		return nil, fmt.Errorf("block %s not found", blockID)
	}
	return rpcResp.Result, nil
}

// ──────────────────────────────────────────────
// Peer status monitor
// ──────────────────────────────────────────────

type PeerStatusResponse struct {
	LocalPeerID string      `json:"localPeerId"`
	Summary     PeerSummary `json:"summary"`
	Peers       []PeerInfo  `json:"peers"`
}

type PeerSummary struct {
	Total          int `json:"total"`
	Connected      int `json:"connected"`
	Disconnected   int `json:"disconnected"`
	NeverConnected int `json:"neverConnected"`
	StaticPeers    int `json:"staticPeers"`
}

type PeerInfo struct {
	PeerID                   string  `json:"peerId"`
	Multiaddr                string  `json:"multiaddr"`
	IsStatic                 bool    `json:"isStatic"`
	ConnectionState          string  `json:"connectionState"`
	HasStream                bool    `json:"hasStream"`
	ConnectedDurationSecs    float64 `json:"connectedDurationSecs,omitempty"`
	DisconnectedDurationSecs float64 `json:"disconnectedDurationSecs,omitempty"`
	ConnectionCount          int     `json:"connectionCount"`
	LastBroadcastSecsAgo     float64 `json:"lastBroadcastSecsAgo,omitempty"`
}

// RunPeerStatusMonitor polls eth_flashblocksPeerStatus on the leader sequencer and alerts
// if any static peers are disconnected. It discovers the leader by calling conductor_leader
// on each configured conductor URL, then queries the same IP on port 8123.
func (m *Monitor) RunPeerStatusMonitor() {
	if len(m.cfg.ConductorURLs) == 0 {
		log.Printf("[PEER] CONDUCTOR_URL not configured, peer status monitor disabled")
		return
	}

	log.Printf("[PEER] Starting peer status monitor (poll every %v, conductors: %v)",
		m.cfg.PeerStatusPollInterval, m.cfg.ConductorURLs)

	ticker := time.NewTicker(m.cfg.PeerStatusPollInterval)
	defer ticker.Stop()

	// Run immediately on start, then on tick
	m.checkPeerStatus()
	for range ticker.C {
		m.checkPeerStatus()
	}
}

// findLeaderSequencerRPC checks each conductor to find the leader, then returns
// the sequencer RPC URL (same host, port 8123).
func (m *Monitor) findLeaderSequencerRPC() (string, error) {
	for _, conductorURL := range m.cfg.ConductorURLs {
		isLeader, err := m.rpcConductorLeader(conductorURL)
		if err != nil {
			if m.cfg.Verbose {
				log.Printf("[PEER] Failed to check conductor %s: %v", conductorURL, err)
			}
			continue
		}
		if isLeader {
			// Replace the conductor port with 8123 to get the sequencer RPC URL
			seqURL := strings.Replace(conductorURL, ":8547", ":8123", 1)
			return seqURL, nil
		}
	}
	return "", fmt.Errorf("no leader found among conductors %v", m.cfg.ConductorURLs)
}

func (m *Monitor) rpcConductorLeader(conductorURL string) (bool, error) {
	reqBody, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "conductor_leader",
		"params":  []any{},
	})

	resp, err := m.rpcClient.Post(conductorURL, "application/json", bytes.NewReader(reqBody))
	if err != nil {
		return false, fmt.Errorf("rpc post: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return false, fmt.Errorf("read body: %w", err)
	}

	var rpcResp struct {
		Result *bool `json:"result"`
		Error  *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &rpcResp); err != nil {
		return false, fmt.Errorf("unmarshal: %w", err)
	}
	if rpcResp.Error != nil {
		return false, fmt.Errorf("rpc error %d: %s", rpcResp.Error.Code, rpcResp.Error.Message)
	}
	if rpcResp.Result == nil {
		return false, fmt.Errorf("empty result")
	}
	return *rpcResp.Result, nil
}

func (m *Monitor) checkPeerStatus() {
	leaderRPC, err := m.findLeaderSequencerRPC()
	if err != nil {
		log.Printf("[PEER] %v", err)
		m.alerter.Send(AlertLeaderFindFail, "Failed to find leader sequencer",
			fmt.Sprintf("Conductors: %v\nError: %v", m.cfg.ConductorURLs, err))
		return
	}

	if m.cfg.Verbose {
		log.Printf("[PEER] Leader sequencer: %s", leaderRPC)
	}

	status, err := m.rpcGetPeerStatus(leaderRPC)
	if err != nil {
		log.Printf("[PEER] Failed to get peer status from %s: %v", leaderRPC, err)
		m.alerter.Send(AlertPeerStatusFail, "Peer status RPC failed",
			fmt.Sprintf("Leader Sequencer: %s\nError: %v", leaderRPC, err))
		return
	}

	if m.cfg.Verbose {
		log.Printf("[PEER] Status: total=%d connected=%d disconnected=%d neverConnected=%d static=%d",
			status.Summary.Total, status.Summary.Connected, status.Summary.Disconnected,
			status.Summary.NeverConnected, status.Summary.StaticPeers)
	}

	// Check static peers with connectionState == "disconnected"
	var disconnectedStatic []PeerInfo
	for _, p := range status.Peers {
		if p.IsStatic && p.ConnectionState == "disconnected" {
			disconnectedStatic = append(disconnectedStatic, p)
		}
	}

	if len(disconnectedStatic) > 0 {
		for _, p := range disconnectedStatic {
			log.Printf("[PEER] Static peer disconnected: peerID=%s addr=%s disconnected_for=%.1fs connections=%d",
				p.PeerID, p.Multiaddr, p.DisconnectedDurationSecs, p.ConnectionCount)
		}

		details := fmt.Sprintf("Leader Sequencer: %s\nLocal Peer: %s\nDisconnected static peers: %d / %d static\n",
			leaderRPC, status.LocalPeerID,
			len(disconnectedStatic), status.Summary.StaticPeers)
		for _, p := range disconnectedStatic {
			details += fmt.Sprintf("\n  PeerID: %s\n  Addr: %s\n  Disconnected for: %.1fs\n  Connection count: %d\n",
				p.PeerID, p.Multiaddr, p.DisconnectedDurationSecs, p.ConnectionCount)
		}
		m.alerter.Send(AlertPeerDisconnect,
			fmt.Sprintf("%d static peer(s) disconnected", len(disconnectedStatic)),
			details)
	} else {
		log.Printf("[PEER] All %d static peers connected", status.Summary.StaticPeers)
	}
}

func (m *Monitor) rpcGetPeerStatus(seqRPCURL string) (*PeerStatusResponse, error) {
	reqBody, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "eth_flashblocksPeerStatus",
		"params":  []any{},
	})

	resp, err := m.rpcClient.Post(seqRPCURL, "application/json", bytes.NewReader(reqBody))
	if err != nil {
		return nil, fmt.Errorf("rpc post: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read body: %w", err)
	}

	var rpcResp struct {
		Result *PeerStatusResponse `json:"result"`
		Error  *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &rpcResp); err != nil {
		return nil, fmt.Errorf("unmarshal: %w", err)
	}
	if rpcResp.Error != nil {
		return nil, fmt.Errorf("rpc error %d: %s", rpcResp.Error.Code, rpcResp.Error.Message)
	}
	if rpcResp.Result == nil {
		return nil, fmt.Errorf("empty result")
	}
	return rpcResp.Result, nil
}

// ──────────────────────────────────────────────
// Utility
// ──────────────────────────────────────────────

func hexToInt64(hexStr string) int64 {
	hexStr = strings.TrimPrefix(hexStr, "0x")
	if hexStr == "" {
		return 0
	}
	n, _ := new(big.Int).SetString(hexStr, 16)
	if n == nil {
		return 0
	}
	return n.Int64()
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen]
}

func (m *Monitor) PrintStats() {
	m.stats.mu.Lock()
	defer m.stats.mu.Unlock()
	log.Printf("[STATS] flashblocks=%d tracked=%d confirmed=%d missing=%d latency_alerts=%d reconnects=%d",
		m.stats.FlashblocksReceived,
		m.stats.TxsTracked,
		m.stats.TxsConfirmed,
		m.stats.TxsMissing,
		m.stats.LatencyAlerts,
		m.stats.Reconnections,
	)
}
