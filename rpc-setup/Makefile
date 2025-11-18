.PHONY: help run stop status

# Default target
help:
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  X Layer RPC Node - Makefile Commands"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@echo "  make run          - Start RPC node services"
	@echo "  make stop         - Stop RPC node services (data preserved)"
	@echo "  make status       - Check service status"
	@echo ""
	@echo "  Note: Run ./one-click-setup.sh for first-time setup"
	@echo "  Note: To delete data, manually run: rm -rf <network>-<rpc>/ .env"
	@echo "  Logs: Use 'docker compose logs' or 'docker compose logs -f'"
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Start services based on RPC_TYPE from .env
run:
	@if [ ! -f .env ]; then \
		echo "❌ Error: .env file not found. Please run ./one-click-setup.sh first"; \
		exit 1; \
	fi
	@echo "🚀 Starting X Layer RPC node..."
	@RPC_TYPE=$$(grep '^RPC_TYPE=' .env | cut -d'=' -f2); \
	NETWORK_TYPE=$$(grep '^NETWORK_TYPE=' .env | cut -d'=' -f2); \
	if [ "$$RPC_TYPE" = "reth" ]; then \
		echo "  Starting op-reth..."; \
		docker compose up -d op-reth; \
		echo "⏳ Waiting for op-reth to be ready (fast startup mode enabled)..."; \
		while [ "$$(docker compose ps op-reth --format json 2>/dev/null | grep -o '"Health":"[^"]*"' | cut -d':' -f2 | tr -d '"')" != "healthy" ]; do \
			sleep 5; \
			printf "."; \
		done; \
		echo ""; \
		echo "  Starting op-node..."; \
		docker compose up -d op-node; \
	else \
		echo "  Starting op-geth..."; \
		docker compose up -d op-geth; \
		echo "⏳ Waiting for op-geth to be ready (this may take several minutes for first start)..."; \
		while [ "$$(docker compose ps op-geth --format json 2>/dev/null | grep -o '"Health":"[^"]*"' | cut -d':' -f2 | tr -d '"')" != "healthy" ]; do \
			sleep 10; \
			printf "."; \
		done; \
		echo ""; \
		echo "  Starting op-node..."; \
		docker compose up -d op-node; \
	fi
	@echo "✅ Services started"
	@echo ""
	@$(MAKE) status

# Stop all services
stop:
	@echo "🛑 Stopping X Layer RPC node..."
	@docker compose down
	@echo "✅ Services stopped"

# Check service status
status:
	@echo "📊 Service Status:"
	@docker compose ps
	@echo ""
	@if [ -f .env ]; then \
		NETWORK_TYPE=$$(grep '^NETWORK_TYPE=' .env | cut -d'=' -f2); \
		RPC_TYPE=$$(grep '^RPC_TYPE=' .env | cut -d'=' -f2); \
		HTTP_PORT=$$(grep '^HTTP_RPC_PORT=' .env | cut -d'=' -f2); \
		WS_PORT=$$(grep '^WEBSOCKET_PORT=' .env | cut -d'=' -f2); \
		NODE_PORT=$$(grep '^NODE_RPC_PORT=' .env | cut -d'=' -f2); \
		echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; \
		echo "📋 Connection Info"; \
		echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; \
		echo "  Network:  $$NETWORK_TYPE"; \
		echo "  RPC Type: $$RPC_TYPE"; \
		echo "  HTTP:     http://localhost:$$HTTP_PORT"; \
		echo "  WS:       ws://localhost:$$WS_PORT"; \
		echo "  Op-Node:  http://localhost:$$NODE_PORT"; \
		echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; \
	fi
