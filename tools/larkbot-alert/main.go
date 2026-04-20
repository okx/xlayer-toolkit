package main

import (
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"
)

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
	log.Printf("  Conductors:      %v", cfg.ConductorURLs)
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
		ticker := time.NewTicker(60 * time.Second)
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

func maskURL(url string) string {
	if url == "" {
		return "(not configured)"
	}
	if len(url) > 30 {
		return url[:30] + "..."
	}
	return url
}
