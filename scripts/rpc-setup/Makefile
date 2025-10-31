.PHONY: help start run stop restart logs status clean

# Default target
help:
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  X Layer RPC Node - Makefile Commands"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@echo "  make run          - Start RPC node services (alias for start)"
	@echo "  make start        - Start RPC node services"
	@echo "  make stop         - Stop RPC node services"
	@echo "  make restart      - Restart RPC node services"
	@echo "  make logs         - View service logs"
	@echo "  make logs-follow  - Follow service logs (Ctrl+C to exit)"
	@echo "  make status       - Check service status"
	@echo "  make clean        - Stop and remove all containers"
	@echo ""
	@echo "  Note: Run ./one-click-setup.sh for first-time setup"
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Start services based on RPC_TYPE from .env
start:
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
		echo "⏳ Waiting for op-reth to be ready..."; \
		sleep 5; \
		echo "  Starting op-node..."; \
		docker compose up -d op-node; \
	else \
		echo "  Starting op-geth..."; \
		docker compose up -d op-geth; \
		echo "⏳ Waiting for op-geth to be ready..."; \
		sleep 5; \
		echo "  Starting op-node..."; \
		docker compose up -d op-node; \
	fi
	@echo "✅ Services started"
	@echo ""
	@$(MAKE) status

# Alias for start
run: start

# Stop all services
stop:
	@echo "🛑 Stopping X Layer RPC node..."
	@docker compose down
	@echo "✅ Services stopped"

# Restart services
restart: stop start

# View logs
logs:
	@docker compose logs

# Follow logs
logs-follow:
	@docker compose logs -f

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

# Clean up everything
clean:
	@echo "🧹 Cleaning up..."
	@docker compose down -v
	@echo "✅ Cleanup complete"

