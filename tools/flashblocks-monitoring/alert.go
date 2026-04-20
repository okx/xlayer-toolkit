package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"
)

// AlertType distinguishes different alert categories for rate limiting.
type AlertType string

const (
	AlertLatency        AlertType = "latency"         // Alert 1: flashblock received too late
	AlertMissing        AlertType = "missing"         // Alert 2: tx missing from canonical block
	AlertWSDown         AlertType = "ws_down"         // WebSocket disconnected
	AlertWSLongDown     AlertType = "ws_long_down"    // WebSocket long time unavailable
	AlertSubscribeFail  AlertType = "subscribe_fail"  // eth_subscribe failed
	AlertPeerDisconnect   AlertType = "peer_disconnect"    // Static peer disconnected
	AlertPeerStatusFail   AlertType = "peer_status_fail"   // Peer status RPC failed
	AlertLeaderFindFail   AlertType = "leader_find_fail"   // Failed to find leader sequencer
)

// Alerter sends alerts to Lark via xmonitor format with rate limiting.
type Alerter struct {
	enabled   bool
	botURL    string
	groupID   string
	rateLimit time.Duration
	client    *http.Client

	mu       sync.Mutex
	lastSent map[AlertType]time.Time
}

func NewAlerter(enabled bool, botURL, groupID string, rateLimit time.Duration) *Alerter {
	return &Alerter{
		enabled:   enabled,
		botURL:    botURL,
		groupID:   groupID,
		rateLimit: rateLimit,
		client:    &http.Client{Timeout: 10 * time.Second},
		lastSent:  make(map[AlertType]time.Time),
	}
}

// Send sends an alert to Lark if rate limit allows.
func (a *Alerter) Send(alertType AlertType, title string, details string) {
	text := fmt.Sprintf("Flashblocks Monitor Alert\n\n[%s] %s\n\n%s\n\nTime: %s",
		alertType, title, details, time.Now().Format("2006-01-02 15:04:05"))

	if !a.enabled || a.botURL == "" || a.groupID == "" {
		log.Printf("[ALERT][%s] %s\n%s", alertType, title, details)
		return
	}

	if !a.canSend(alertType) {
		log.Printf("[ALERT][%s][rate-limited] %s", alertType, title)
		return
	}

	// Build text message content (content is a JSON string)
	textContent := map[string]string{
		"text": text,
	}
	contentBytes, _ := json.Marshal(textContent)

	// Build xmonitor format request body
	request := map[string]interface{}{
		"receiveId":  a.groupID,
		"content":    string(contentBytes),
		"msgType":    "text",
		"repeatFlag": fmt.Sprintf("flashblocks-monitor-%s-%d", alertType, time.Now().UnixMilli()),
	}

	body, err := json.Marshal(request)
	if err != nil {
		log.Printf("Failed to marshal lark message: %v", err)
		return
	}

	req, err := http.NewRequest("POST", a.botURL, bytes.NewReader(body))
	if err != nil {
		log.Printf("Failed to create lark request: %v", err)
		return
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := a.client.Do(req)
	if err != nil {
		log.Printf("Failed to send lark alert: %v", err)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		log.Printf("Lark webhook returned status %d", resp.StatusCode)
	} else {
		log.Printf("[ALERT][%s] Sent to Lark group %s: %s", alertType, a.groupID, title)
	}
}

func (a *Alerter) canSend(alertType AlertType) bool {
	a.mu.Lock()
	defer a.mu.Unlock()

	last, ok := a.lastSent[alertType]
	if ok && time.Since(last) < a.rateLimit {
		return false
	}
	a.lastSent[alertType] = time.Now()
	return true
}
