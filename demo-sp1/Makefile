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
	@echo "  make run          Start all services (one command to run everything)"
	@echo "  make stop         Stop all services"
	@echo "  make logs         Show all logs"
	@echo "  make logs-proposer    Show proposer logs"
	@echo "  make logs-challenger  Show challenger logs"
	@echo "  make clean        Clean all artifacts"

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
	echo "# ============================================" > $(ENV_FILE) && \
	echo "# demo-sp1 Configuration" >> $(ENV_FILE) && \
	echo "# ============================================" >> $(ENV_FILE) && \
	echo "" >> $(ENV_FILE) && \
	echo "# RPC Endpoints" >> $(ENV_FILE) && \
	echo "L1_RPC=http://anvil:8545" >> $(ENV_FILE) && \
	echo "L2_RPC=http://node:8546" >> $(ENV_FILE) && \
	echo "" >> $(ENV_FILE) && \
	echo "# Contract Addresses" >> $(ENV_FILE) && \
	echo "OUTPUT_ORACLE_ADDRESS=$$OUTPUT_ORACLE" >> $(ENV_FILE) && \
	echo "SP1_VERIFIER_ADDRESS=$$SP1_VERIFIER" >> $(ENV_FILE) && \
	echo "DISPUTE_GAME_FACTORY_ADDRESS=$$DISPUTE_FACTORY" >> $(ENV_FILE) && \
	echo "" >> $(ENV_FILE) && \
	echo "# Proposer Settings" >> $(ENV_FILE) && \
	echo "BATCH_INTERVAL=100" >> $(ENV_FILE) && \
	echo "PRIVATE_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" >> $(ENV_FILE) && \
	echo "PROPOSER_ADDRESS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8" >> $(ENV_FILE) && \
	echo "" >> $(ENV_FILE) && \
	echo "# Challenger Settings" >> $(ENV_FILE) && \
	echo "CHALLENGE_EVERY_N_OUTPUTS=10" >> $(ENV_FILE) && \
	echo "FORCE_CHALLENGE=true" >> $(ENV_FILE) && \
	echo "FETCH_INTERVAL=2" >> $(ENV_FILE) && \
	echo "" >> $(ENV_FILE) && \
	echo "# SP1 Prover Settings" >> $(ENV_FILE) && \
	echo "SP1_PROVER=mock" >> $(ENV_FILE) && \
	echo "SP1_PRIVATE_KEY=" >> $(ENV_FILE) && \
	echo "" >> $(ENV_FILE) && \
	echo "✓ OutputOracle: $$OUTPUT_ORACLE" && \
	echo "✓ SP1Verifier: $$SP1_VERIFIER" && \
	echo "✓ DisputeGameFactory: $$DISPUTE_FACTORY" && \
	echo "✓ Environment saved to $(ENV_FILE)"

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
	@# Step 4: Start Batcher, Proposer and Challenger
	@echo "[4/4] Starting Batcher, Proposer and Challenger..."
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) up -d batcher proposer challenger
	@echo ""
	@echo "═══════════════════════════════════════════════"
	@echo "  ZK Bisection System Ready!"
	@echo "═══════════════════════════════════════════════"
	@echo ""
	@echo "  Anvil (L1):     http://localhost:8545"
	@echo "  Node (L2):      http://localhost:8546"
	@echo ""
	@echo "  Proposer:       Submitting batches every 100 blocks"
	@echo "  Challenger:     Challenging every 10 batches automatically"
	@echo ""
	@echo "  View logs:      make logs"
	@echo "  Stop:           make stop"
	@echo ""
	@cat $(ENV_FILE) 2>/dev/null || true

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
