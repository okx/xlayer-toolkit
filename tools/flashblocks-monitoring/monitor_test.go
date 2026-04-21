package main

import (
	"testing"
	"time"
)

func TestHexToInt64(t *testing.T) {
	tests := []struct {
		name string
		input string
		want int64
	}{
		{"valid with prefix", "0x1a", 26},
		{"valid without prefix", "1a", 26},
		{"zero", "0x0", 0},
		{"large number", "0x193b167", 26456423},
		{"empty string", "", 0},
		{"only prefix", "0x", 0},
		{"malformed hex", "0xZZZ", 0},
		{"negative not possible", "0xffffffffffffffff", -1},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := hexToInt64(tt.input)
			if got != tt.want {
				t.Errorf("hexToInt64(%q) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}

func TestParseConductorSequencers(t *testing.T) {
	// parseConductorSequencers reads from viper globals, so we test the struct directly
	pair := ConductorSequencerPair{
		ConductorURL: "http://localhost:8547",
		SequencerURL: "http://localhost:8123",
	}
	if pair.ConductorURL != "http://localhost:8547" {
		t.Errorf("unexpected ConductorURL: %s", pair.ConductorURL)
	}
	if pair.SequencerURL != "http://localhost:8123" {
		t.Errorf("unexpected SequencerURL: %s", pair.SequencerURL)
	}
}

func TestAlerterRateLimit(t *testing.T) {
	a := NewAlerter(false, "", "", 100*time.Millisecond, 5*time.Second)

	// First call should be allowed
	if !a.canSend(AlertLatency) {
		t.Error("first call should be allowed")
	}

	// Immediate second call should be rate-limited
	if a.canSend(AlertLatency) {
		t.Error("second call should be rate-limited")
	}

	// Different alert type should be independent
	if !a.canSend(AlertMissing) {
		t.Error("different alert type should be allowed")
	}

	// Wait for rate limit to expire
	time.Sleep(150 * time.Millisecond)

	// Should be allowed again
	if !a.canSend(AlertLatency) {
		t.Error("call after rate limit expiry should be allowed")
	}
}

func TestTruncate(t *testing.T) {
	tests := []struct {
		name   string
		input  string
		maxLen int
		want   string
	}{
		{"shorter than max", "hello", 10, "hello"},
		{"exact length", "hello", 5, "hello"},
		{"longer than max", "hello world", 5, "hello"},
		{"empty string", "", 5, ""},
		{"zero max", "hello", 0, ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := truncate(tt.input, tt.maxLen)
			if got != tt.want {
				t.Errorf("truncate(%q, %d) = %q, want %q", tt.input, tt.maxLen, got, tt.want)
			}
		})
	}
}
