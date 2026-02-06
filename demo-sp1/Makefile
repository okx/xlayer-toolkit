# demo-sp1: ZK Bisection Fault Proof System
# All services run in Docker containers

.PHONY: build run stop deploy-contracts clean logs help

DOCKER_COMPOSE = docker compose -p demo-sp1
COMPOSE_FILE = docker-compose.yaml
ENV_FILE = .env

# L1 Configuration
L1_RPC = http://127.0.0.1:8545
DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# =============================================================================
# Help
# =============================================================================

help:
	@echo "demo-sp1: ZK Bisection Fault Proof System"
	@echo ""
	@echo "Commands:"
	@echo "  make run              Start all services"
	@echo "  make stop             Stop all services"
	@echo "  make logs             Show all logs"
	@echo "  make logs-proposer    Show proposer logs"
	@echo "  make logs-challenger  Show challenger logs"
	@echo "  make logs-benchmarker Show benchmarker logs"
	@echo "  make clean            Clean all artifacts"
	@echo ""
	@echo "Config (.env):"
	@echo "  BENCHMARK_TPS=100        Target TPS (0=disabled)"

# =============================================================================
# Build
# =============================================================================

build:
	@echo "Building Docker images..."
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) build
	@echo "✓ Docker images built"

# Force rebuild (no cache)
build-force:
	@echo "Force rebuilding Docker images (no cache)..."
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) build --no-cache
	@echo "✓ Docker images rebuilt"

# =============================================================================
# Contract Deployment (local, like demo)
# =============================================================================

deploy-contracts:
	@echo "Deploying contracts..."
	@cd contracts && ([ -d lib/forge-std ] || forge install foundry-rs/forge-std --no-git)
	@cd contracts && forge script script/Deploy.s.sol:Deploy \
		--rpc-url $(L1_RPC) \
		--private-key $(DEPLOYER_KEY) \
		--broadcast 2>&1 | tee /tmp/deploy.log
	@OUTPUT_ORACLE=$$(grep "OutputOracle deployed at:" /tmp/deploy.log | awk '{print $$NF}') && \
	SP1_VERIFIER=$$(grep "SP1Verifier deployed at:" /tmp/deploy.log | awk '{print $$NF}') && \
	DISPUTE_FACTORY=$$(grep "DisputeGameFactory deployed at:" /tmp/deploy.log | awk '{print $$NF}') && \
	if [ ! -f $(ENV_FILE) ]; then \
		echo "Creating .env from env.example..." && \
		cp env.example $(ENV_FILE); \
	fi && \
	sed -i.bak "s|^OUTPUT_ORACLE_ADDRESS=.*|OUTPUT_ORACLE_ADDRESS=$$OUTPUT_ORACLE|" $(ENV_FILE) && \
	sed -i.bak "s|^SP1_VERIFIER_ADDRESS=.*|SP1_VERIFIER_ADDRESS=$$SP1_VERIFIER|" $(ENV_FILE) && \
	sed -i.bak "s|^DISPUTE_GAME_FACTORY_ADDRESS=.*|DISPUTE_GAME_FACTORY_ADDRESS=$$DISPUTE_FACTORY|" $(ENV_FILE) && \
	rm -f $(ENV_FILE).bak && \
	echo "✓ OutputOracle: $$OUTPUT_ORACLE" && \
	echo "✓ SP1Verifier: $$SP1_VERIFIER" && \
	echo "✓ DisputeGameFactory: $$DISPUTE_FACTORY" && \
	echo "✓ Contract addresses updated in $(ENV_FILE)"

# =============================================================================
# Run Services (One Command - Like demo)
# =============================================================================

run: stop build
	@echo ""
	@echo "╔═══════════════════════════════════════════════╗"
	@echo "║   Starting ZK Bisection Fault Proof System    ║"
	@echo "╚═══════════════════════════════════════════════╝"
	@echo ""
	@# Step 1: Start Anvil
	@echo "[1/4] Starting Anvil (L1)..."
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) up -d anvil
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		if cast block-number --rpc-url $(L1_RPC) >/dev/null 2>&1; then \
			echo "      ✓ Anvil ready"; \
			break; \
		fi; \
		sleep 1; \
	done
	@# Step 2: Deploy contracts (local)
	@echo "[2/4] Deploying contracts..."
	@$(MAKE) deploy-contracts
	@# Step 3: Start Node
	@echo "[3/4] Starting Node (mock L2)..."
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) up -d node
	@sleep 2
	@# Step 4: Start all services
	@echo "[4/4] Starting Batcher, Proposer, Challenger, Benchmarker..."
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) up -d batcher proposer challenger benchmarker
	@echo ""
	@echo "═══════════════════════════════════════════════"
	@echo "  ZK Bisection System Ready!"
	@echo "═══════════════════════════════════════════════"
	@echo ""
	@echo "  Anvil (L1):     http://localhost:8545"
	@echo "  Node (L2):      http://localhost:8546"
	@echo "  Benchmark TPS:  $${BENCHMARK_TPS:-100}"
	@echo ""
	@echo "  View logs:      make logs"
	@echo "  Stop:           make stop"
	@echo ""

stop:
	@echo "Stopping all services..."
	@-$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) down 2>/dev/null
	@echo "✓ Stopped"

# =============================================================================
# Logs
# =============================================================================

logs:
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) logs -f

logs-anvil:
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) logs -f anvil

logs-node:
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) logs -f node

logs-proposer:
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) logs -f proposer

logs-challenger:
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) logs -f challenger

logs-batcher:
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) logs -f batcher

logs-benchmarker:
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) logs -f benchmarker

# =============================================================================
# Clean
# =============================================================================

clean: stop
	@echo "Cleaning..."
	@rm -rf target/
	@rm -rf contracts/out/
	@rm -rf contracts/cache/
	@rm -rf contracts/broadcast/
	@rm -f $(ENV_FILE)
	@echo "✓ Clean complete"
