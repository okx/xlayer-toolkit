.PHONY: help run stop status

# Default target
help:
	@printf "\033[0;36m  +--------------------------------------------------+\033[0m\n"
	@printf "\033[0;36m  |      \033[1mX Layer RPC Node - Makefile Commands\033[0m\033[0;36m          |\033[0m\n"
	@printf "\033[0;36m  +--------------------------------------------------+\033[0m\n"
	@echo ""
	@printf "\033[0;32m    make run     \033[0m - Start RPC node services\n"
	@printf "\033[0;32m    make stop    \033[0m - Stop RPC node services\n"
	@printf "\033[0;32m    make status  \033[0m - Check service status\n"
	@echo ""
	@printf "\033[2m    Note: Run ./one-click-setup.sh for first-time setup\033[0m\n"
	@printf "\033[2m    Logs: docker compose logs -f\033[0m\n"
	@echo ""

# Start services based on RPC_TYPE from .env
run:
	@if [ ! -f .env ]; then \
		printf "\033[0;31m  [-] Error: .env not found. Run ./one-click-setup.sh first\033[0m\n"; \
		exit 1; \
	fi
	@printf "\033[0;36m  [*] Starting X Layer RPC node...\033[0m\n"
	@RPC_TYPE=$$(grep '^RPC_TYPE=' .env | cut -d'=' -f2); \
	NETWORK_TYPE=$$(grep '^NETWORK_TYPE=' .env | cut -d'=' -f2); \
	PROJECT_NAME="xlayer-$$NETWORK_TYPE-$$RPC_TYPE"; \
	if [ "$$RPC_TYPE" = "reth" ]; then \
		printf "\033[0;36m  [*] Starting op-reth...\033[0m\n"; \
		docker compose -p $$PROJECT_NAME up -d op-reth; \
		printf "\033[0;36m  [*] Waiting for op-reth to be ready...\033[0m"; \
		while [ "$$(docker compose -p $$PROJECT_NAME ps op-reth --format json 2>/dev/null | grep -o '"Health":"[^"]*"' | cut -d':' -f2 | tr -d '"')" != "healthy" ]; do \
			sleep 5; \
			printf "."; \
		done; \
		echo ""; \
		printf "\033[0;36m  [*] Starting op-node...\033[0m\n"; \
		docker compose -p $$PROJECT_NAME up -d op-node; \
	else \
		printf "\033[0;36m  [*] Starting op-geth...\033[0m\n"; \
		docker compose -p $$PROJECT_NAME up -d op-geth; \
		printf "\033[0;36m  [*] Waiting for op-geth to be ready...\033[0m"; \
		while [ "$$(docker compose -p $$PROJECT_NAME ps op-geth --format json 2>/dev/null | grep -o '"Health":"[^"]*"' | cut -d':' -f2 | tr -d '"')" != "healthy" ]; do \
			sleep 10; \
			printf "."; \
		done; \
		echo ""; \
		printf "\033[0;36m  [*] Starting op-node...\033[0m\n"; \
		docker compose -p $$PROJECT_NAME up -d op-node; \
	fi
	@printf "\033[0;32m  [+] Services started\033[0m\n"
	@echo ""
	@if [ -f .env ]; then \
		NETWORK_TYPE=$$(grep '^NETWORK_TYPE=' .env | cut -d'=' -f2); \
		RPC_TYPE=$$(grep '^RPC_TYPE=' .env | cut -d'=' -f2); \
		HTTP_PORT=$$(grep '^HTTP_RPC_PORT=' .env | cut -d'=' -f2); \
		WS_PORT=$$(grep '^WEBSOCKET_PORT=' .env | cut -d'=' -f2); \
		NODE_PORT=$$(grep '^NODE_RPC_PORT=' .env | cut -d'=' -f2); \
		printf "\033[0;36m  +--------------------------------------------------+\033[0m\n"; \
		printf "\033[0;36m  |         \033[1mConnection Info\033[0m\033[0;36m                             |\033[0m\n"; \
		printf "\033[0;36m  +--------------------------------------------------+\033[0m\n"; \
		printf "\033[2m    Network:  $$NETWORK_TYPE\033[0m\n"; \
		printf "\033[2m    RPC Type: $$RPC_TYPE\033[0m\n"; \
		printf "\033[0;32m    HTTP:     http://localhost:$$HTTP_PORT\033[0m\n"; \
		printf "\033[0;32m    WS:       ws://localhost:$$WS_PORT\033[0m\n"; \
		printf "\033[0;32m    Op-Node:  http://localhost:$$NODE_PORT\033[0m\n"; \
	fi

# Stop services
# Usage: make stop [TARGET=<network>-<rpc>]
#   - make stop              : Stop services based on current .env file
#   - make stop TARGET=testnet-geth  : Stop specific instance by target directory name
# Note: docker compose down does NOT remove volumes, so data is preserved
stop:
	@if [ -n "$(TARGET)" ]; then \
		printf "\033[0;36m  [*] Stopping X Layer RPC node: $(TARGET)...\033[0m\n"; \
		NETWORK_TYPE=$$(echo "$(TARGET)" | cut -d'-' -f1); \
		RPC_TYPE=$$(echo "$(TARGET)" | cut -d'-' -f2); \
		if [ -z "$$NETWORK_TYPE" ] || [ -z "$$RPC_TYPE" ]; then \
			printf "\033[0;31m  [-] Invalid TARGET format. Expected: <network>-<rpc>\033[0m\n"; \
			exit 1; \
		fi; \
		PROJECT_NAME="xlayer-$$NETWORK_TYPE-$$RPC_TYPE"; \
		docker compose -p $$PROJECT_NAME down; \
		printf "\033[0;32m  [+] Services stopped for $(TARGET) (data preserved)\033[0m\n"; \
	else \
		if [ ! -f .env ]; then \
			printf "\033[0;31m  [-] .env not found. Run ./one-click-setup.sh or use TARGET=<network>-<rpc>\033[0m\n"; \
			exit 1; \
		fi; \
		RPC_TYPE=$$(grep '^RPC_TYPE=' .env | cut -d'=' -f2); \
		NETWORK_TYPE=$$(grep '^NETWORK_TYPE=' .env | cut -d'=' -f2); \
		PROJECT_NAME="xlayer-$$NETWORK_TYPE-$$RPC_TYPE"; \
		printf "\033[0;36m  [*] Stopping X Layer RPC node ($$PROJECT_NAME)...\033[0m\n"; \
		docker compose -p $$PROJECT_NAME down; \
		printf "\033[0;32m  [+] Services stopped (data preserved)\033[0m\n"; \
	fi

# Check service status
status:
	@if [ -f .env ]; then \
		RPC_TYPE=$$(grep '^RPC_TYPE=' .env | cut -d'=' -f2); \
		NETWORK_TYPE=$$(grep '^NETWORK_TYPE=' .env | cut -d'=' -f2); \
		PROJECT_NAME="xlayer-$$NETWORK_TYPE-$$RPC_TYPE"; \
		printf "\033[0;36m  [*] Service Status ($$PROJECT_NAME):\033[0m\n"; \
		docker compose -p $$PROJECT_NAME ps; \
	else \
		printf "\033[0;36m  [*] Service Status:\033[0m\n"; \
		docker compose ps; \
	fi
	@echo ""
	@if [ -f .env ]; then \
		NETWORK_TYPE=$$(grep '^NETWORK_TYPE=' .env | cut -d'=' -f2); \
		RPC_TYPE=$$(grep '^RPC_TYPE=' .env | cut -d'=' -f2); \
		HTTP_PORT=$$(grep '^HTTP_RPC_PORT=' .env | cut -d'=' -f2); \
		WS_PORT=$$(grep '^WEBSOCKET_PORT=' .env | cut -d'=' -f2); \
		NODE_PORT=$$(grep '^NODE_RPC_PORT=' .env | cut -d'=' -f2); \
		printf "\033[0;36m  +--------------------------------------------------+\033[0m\n"; \
		printf "\033[0;36m  |         \033[1mConnection Info\033[0m\033[0;36m                             |\033[0m\n"; \
		printf "\033[0;36m  +--------------------------------------------------+\033[0m\n"; \
		printf "\033[2m    Network:  $$NETWORK_TYPE\033[0m\n"; \
		printf "\033[2m    RPC Type: $$RPC_TYPE\033[0m\n"; \
		printf "\033[0;32m    HTTP:     http://localhost:$$HTTP_PORT\033[0m\n"; \
		printf "\033[0;32m    WS:       ws://localhost:$$WS_PORT\033[0m\n"; \
		printf "\033[0;32m    Op-Node:  http://localhost:$$NODE_PORT\033[0m\n"; \
	fi
