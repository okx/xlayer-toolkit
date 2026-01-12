.PHONY: help run stop status

# Default target
help:
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  X Layer RPC Node - Makefile Commands"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@echo "  make run          - Start RPC node services"
	@echo "  make stop         - Stop RPC node services (based on .env)"
	@echo "  make stop TARGET=<network>-<rpc>  - Stop specific instance"
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
	PROJECT_NAME="xlayer-$$NETWORK_TYPE-$$RPC_TYPE"; \
	if [ "$$RPC_TYPE" = "reth" ]; then \
		echo "  Starting op-reth..."; \
		docker compose -p $$PROJECT_NAME up -d op-reth; \
		echo "⏳ Waiting for op-reth to be ready (fast startup mode enabled)..."; \
		while [ "$$(docker compose -p $$PROJECT_NAME ps op-reth --format json 2>/dev/null | grep -o '"Health":"[^"]*"' | cut -d':' -f2 | tr -d '"')" != "healthy" ]; do \
			sleep 5; \
			printf "."; \
		done; \
		echo ""; \
		echo "  Starting op-node..."; \
		docker compose -p $$PROJECT_NAME up -d op-node; \
	else \
		echo "  Starting op-geth..."; \
		docker compose -p $$PROJECT_NAME up -d op-geth; \
		echo "⏳ Waiting for op-geth to be ready (this may take several minutes for first start)..."; \
		while [ "$$(docker compose -p $$PROJECT_NAME ps op-geth --format json 2>/dev/null | grep -o '"Health":"[^"]*"' | cut -d':' -f2 | tr -d '"')" != "healthy" ]; do \
			sleep 10; \
			printf "."; \
		done; \
		echo ""; \
		echo "  Starting op-node..."; \
		docker compose -p $$PROJECT_NAME up -d op-node; \
	fi
	@echo "✅ Services started"
	@echo ""
	@$(MAKE) status

# Stop services
# Usage: make stop [TARGET=<network>-<rpc>]
#   - make stop              : Stop services based on current .env file
#   - make stop TARGET=testnet-geth  : Stop specific instance by target directory name
# Note: docker compose down does NOT remove volumes, so data is preserved
stop:
	@if [ -n "$(TARGET)" ]; then \
		echo "🛑 Stopping X Layer RPC node: $(TARGET)..."; \
		NETWORK_TYPE=$$(echo "$(TARGET)" | cut -d'-' -f1); \
		RPC_TYPE=$$(echo "$(TARGET)" | cut -d'-' -f2); \
		if [ -z "$$NETWORK_TYPE" ] || [ -z "$$RPC_TYPE" ]; then \
			echo "❌ Error: Invalid TARGET format. Expected: <network>-<rpc> (e.g., testnet-geth)"; \
			exit 1; \
		fi; \
		PROJECT_NAME="xlayer-$$NETWORK_TYPE-$$RPC_TYPE"; \
		echo "  Stopping containers for $$NETWORK_TYPE-$$RPC_TYPE (project: $$PROJECT_NAME)..."; \
		docker compose -p $$PROJECT_NAME down; \
		echo "✅ Services stopped for $(TARGET) (data preserved)"; \
	else \
		if [ ! -f .env ]; then \
			echo "❌ Error: .env file not found. Please run ./one-click-setup.sh first or specify TARGET parameter"; \
			echo "  Usage: make stop TARGET=<network>-<rpc>"; \
			exit 1; \
		fi; \
		RPC_TYPE=$$(grep '^RPC_TYPE=' .env | cut -d'=' -f2); \
		NETWORK_TYPE=$$(grep '^NETWORK_TYPE=' .env | cut -d'=' -f2); \
		PROJECT_NAME="xlayer-$$NETWORK_TYPE-$$RPC_TYPE"; \
		echo "🛑 Stopping X Layer RPC node (based on .env, project: $$PROJECT_NAME)..."; \
		docker compose -p $$PROJECT_NAME down; \
		echo "✅ Services stopped (data preserved)"; \
	fi

# Check service status
status:
	@if [ -f .env ]; then \
		RPC_TYPE=$$(grep '^RPC_TYPE=' .env | cut -d'=' -f2); \
		NETWORK_TYPE=$$(grep '^NETWORK_TYPE=' .env | cut -d'=' -f2); \
		PROJECT_NAME="xlayer-$$NETWORK_TYPE-$$RPC_TYPE"; \
		echo "📊 Service Status (project: $$PROJECT_NAME):"; \
		docker compose -p $$PROJECT_NAME ps; \
	else \
		echo "📊 Service Status:"; \
		docker compose ps; \
	fi
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
