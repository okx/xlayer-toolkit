package main

import (
	"log"
	"os"
	"strings"
	"time"

	"github.com/spf13/viper"
)

type Config struct {
	WSURL                  string
	RPCURL                 string
	LarkBotURL             string
	LarkGroupID            string
	AlertEnabled           bool
	MaxFlashblockDelay     time.Duration
	TxCheckDelay           time.Duration
	AlertRateLimit         time.Duration
	WSLongDownThreshold    time.Duration
	VerifyTimeout          time.Duration
	RPCTimeout             time.Duration
	PeerStatusPollInterval time.Duration
	ConductorURLs          []string
	Verbose                bool
}

func LoadConfig(configPath string) *Config {
	if _, err := os.Stat(configPath); err == nil {
		viper.SetConfigFile(configPath)
		if err := viper.ReadInConfig(); err != nil {
			log.Fatalf("Failed to read config file %s: %v", configPath, err)
		}
		log.Printf("Loaded config from %s", configPath)
	} else {
		log.Printf("Config file %s not found, using defaults + env", configPath)
	}

	// 环境变量覆盖
	viper.AutomaticEnv()

	// 设置默认值
	viper.SetDefault("WS_URL", "ws://10.2.29.244:8546")
	viper.SetDefault("RPC_URL", "http://10.2.29.244:8545")
	viper.SetDefault("APM_BOT_URL", "https://apmapi.okg.com/alarm/channel/robot/send?receiveIdType=chat_id")
	viper.SetDefault("LARK_GROUP_ID", "oc_16b2e6dbfde509708503a76cee8ae8e4")
	viper.SetDefault("ALERT_ENABLED", true)
	viper.SetDefault("MAX_FLASHBLOCK_DELAY_MS", 1000)
	viper.SetDefault("TX_CHECK_DELAY_MS", 1000)
	viper.SetDefault("ALERT_RATE_LIMIT_S", 30)
	viper.SetDefault("WS_LONG_DOWN_THRESHOLD_S", 60)
	viper.SetDefault("VERIFY_TIMEOUT_S", 5)
	viper.SetDefault("RPC_TIMEOUT_S", 10)
	viper.SetDefault("PEER_STATUS_POLL_INTERVAL_S", 30)
	viper.SetDefault("CONDUCTOR_URL", "")
	viper.SetDefault("VERBOSE", false)

	return &Config{
		WSURL:                  viper.GetString("WS_URL"),
		RPCURL:                 viper.GetString("RPC_URL"),
		LarkBotURL:             viper.GetString("APM_BOT_URL"),
		LarkGroupID:            viper.GetString("LARK_GROUP_ID"),
		AlertEnabled:           viper.GetBool("ALERT_ENABLED"),
		MaxFlashblockDelay:     time.Duration(viper.GetInt("MAX_FLASHBLOCK_DELAY_MS")) * time.Millisecond,
		TxCheckDelay:           time.Duration(viper.GetInt("TX_CHECK_DELAY_MS")) * time.Millisecond,
		AlertRateLimit:         time.Duration(viper.GetInt("ALERT_RATE_LIMIT_S")) * time.Second,
		WSLongDownThreshold:    time.Duration(viper.GetInt("WS_LONG_DOWN_THRESHOLD_S")) * time.Second,
		VerifyTimeout:          time.Duration(viper.GetInt("VERIFY_TIMEOUT_S")) * time.Second,
		RPCTimeout:             time.Duration(viper.GetInt("RPC_TIMEOUT_S")) * time.Second,
		PeerStatusPollInterval: time.Duration(viper.GetInt("PEER_STATUS_POLL_INTERVAL_S")) * time.Second,
		ConductorURLs:          parseConductorURLs(viper.GetString("CONDUCTOR_URL")),
		Verbose:                viper.GetBool("VERBOSE"),
	}
}

func parseConductorURLs(raw string) []string {
	if raw == "" {
		return nil
	}
	var urls []string
	for _, u := range strings.Split(raw, ",") {
		u = strings.TrimSpace(u)
		if u != "" {
			urls = append(urls, u)
		}
	}
	return urls
}
