package main

import (
	"flag"
	"fmt"
	"log"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"
)

const statsLogInterval = 60 * time.Second

func main() {
	configPath := flag.String("config", "cfg.yml", "Path to config file")
	flag.Parse()

	cfg := LoadConfig(*configPath)

	log.SetFlags(log.Ldate | log.Ltime | log.Lmicroseconds)

	log.Println("========================================")
	log.Println("  Flashblocks Monitor")
	log.Println("========================================")
	log.Printf("  WS URL:          %s", cfg.WSURL)
	log.Printf("  RPC URL:         %s", cfg.RPCURL)
	log.Printf("  Lark Bot URL:    %s", maskURL(cfg.LarkBotURL))
	log.Printf("  Lark Group ID:   %s", cfg.LarkGroupID)
	log.Printf("  Alert Enabled:   %v", cfg.AlertEnabled)
	log.Printf("  Max Delay:       %v", cfg.MaxFlashblockDelay)
	log.Printf("  TX Check Delay:  %v", cfg.TxCheckDelay)
	log.Printf("  Alert Rate Limit:%v", cfg.AlertRateLimit)
	log.Printf("  Verify Timeout:  %v", cfg.VerifyTimeout)
	log.Printf("  RPC Timeout:     %v", cfg.RPCTimeout)
	for i, pair := range cfg.ConductorSequencers {
		log.Printf("  Conductor %d:     %s -> %s", i+1, pair.ConductorURL, pair.SequencerURL)
	}
	log.Printf("  Peer Poll:       %v", cfg.PeerStatusPollInterval)
	log.Printf("  Verbose:         %v", cfg.Verbose)
	log.Println("========================================")

	monitor := NewMonitor(cfg)

	// Start WebSocket listener
	go monitor.RunWSListener()

	// Start peer status monitor
	go monitor.RunPeerStatusMonitor()

	// Periodic stats logging
	go func() {
		ticker := time.NewTicker(statsLogInterval)
		defer ticker.Stop()
		for range ticker.C {
			monitor.PrintStats()
		}
	}()

	// Graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sigCh

	log.Printf("Received signal %v, shutting down...", sig)
	monitor.PrintStats()
}

func maskURL(rawURL string) string {
	if rawURL == "" {
		return "(not configured)"
	}
	u, err := url.Parse(rawURL)
	if err != nil {
		return "(invalid URL)"
	}
	return fmt.Sprintf("%s://%s/...", u.Scheme, u.Host)
}
