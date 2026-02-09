# demo-sp1: ZK Bisection Fault Proof System
# All services run in Docker containers

.PHONY: build run stop deploy-contracts clean logs help build-elf

DOCKER_COMPOSE = docker compose -p demo-sp1
COMPOSE_FILE = docker-compose.yaml
ENV_FILE = .env
ELF_DIR = elf
ELF_FILE = $(ELF_DIR)/block-verify-program

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
	@echo "  make run              Start all services (auto-detects SP1 mode)"
	@echo "  make stop             Stop all services"
	@echo "  make logs             Show all logs"
	@echo "  make logs-proposer    Show proposer logs"
	@echo "  make logs-challenger  Show challenger logs"
	@echo "  make build-elf        Build SP1 ELF (uses Docker, no local install needed)"
	@echo "  make build-elf-local  Build SP1 ELF (requires local sp1 toolchain)"
	@echo "  make clean            Clean all artifacts"
	@echo ""
	@echo "Config (.env):"
	@echo "  SP1_PROVER=false      Mock mode (default, fast)"
	@echo "  SP1_PROVER=true       SP1 Network mode (real ZK proof)"
	@echo "  BENCHMARK_TPS=100     Target TPS (0=disabled)"

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
# SP1 ELF Build (for SP1 mode) - Uses Docker to avoid local toolchain issues
# =============================================================================

# Dockerfile for ELF builder (created on-the-fly)
define ELF_BUILDER_DOCKERFILE
FROM rust:1.85-bookworm
RUN apt-get update && apt-get install -y curl ca-certificates && rm -rf /var/lib/apt/lists/*
ENV PATH="/root/.sp1/bin:$$PATH"
RUN curl -L https://sp1.succinct.xyz | bash && /root/.sp1/bin/sp1up
WORKDIR /app
endef
export ELF_BUILDER_DOCKERFILE

build-elf:
	@echo "Building SP1 ELF (using Docker)..."
	@mkdir -p $(ELF_DIR)
	@# Build custom Docker image with SP1 toolchain
	@echo "$$ELF_BUILDER_DOCKERFILE" | docker build -t sp1-elf-builder -f - . 2>&1 | tail -5
	@# Build ELF inside container (mount entire project)
	@docker run --rm \
		-v $(PWD):/app \
		-w /app \
		sp1-elf-builder \
		sh -c "cd programs/block-verify && cargo prove build 2>&1 && \
		       mkdir -p /app/elf && \
		       find /app/target -name 'block-verify-program' -path '*elf-compilation*' -type f -exec cp {} /app/elf/ \; 2>/dev/null || \
		       find /root -name 'block-verify-program' -path '*elf-compilation*' -type f -exec cp {} /app/elf/ \; 2>/dev/null || true"
	@if [ -f $(ELF_FILE) ]; then \
		echo "✓ ELF built: $(ELF_FILE)"; \
	else \
		echo "ERROR: ELF build failed. Check Docker logs above."; \
		exit 1; \
	fi

# Alternative: Build ELF locally (requires SP1 toolchain installed)
build-elf-local:
	@echo "Building SP1 ELF (local)..."
	@if ! command -v cargo-prove >/dev/null 2>&1; then \
		echo "ERROR: SP1 toolchain not installed!"; \
		echo "Install: curl -L https://sp1.succinct.xyz | bash && sp1up"; \
		exit 1; \
	fi
	@mkdir -p $(ELF_DIR)
	@cd programs/block-verify && cargo prove build
	@ELF_SRC=$$(find target -name "block-verify-program" -path "*elf-compilation*" -type f 2>/dev/null | head -1) && \
	if [ -n "$$ELF_SRC" ]; then \
		cp "$$ELF_SRC" $(ELF_FILE) && \
		echo "✓ ELF built: $(ELF_FILE)"; \
	else \
		echo "ERROR: ELF not found"; \
		exit 1; \
	fi

# =============================================================================
# Contract Deployment
# =============================================================================

deploy-contracts:
	@echo "Deploying contracts..."
	@cd contracts && ([ -d lib/forge-std ] || forge install foundry-rs/forge-std --no-git)
	@cd contracts && forge script script/Deploy.s.sol:Deploy \
		--rpc-url $(L1_RPC) \
		--private-key $(DEPLOYER_KEY) \
		--broadcast 2>&1 | tee /tmp/deploy.log
	@OUTPUT_ORACLE=$$(grep "OutputOracle deployed at:" /tmp/deploy.log | awk '{print $$NF}') && \
	SP1_VERIFIER=$$(grep "SP1Verifier deployed at:\|MockSP1Verifier deployed at:" /tmp/deploy.log | awk '{print $$NF}') && \
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
# Run Services
# =============================================================================

run: stop build
	@echo ""
	@echo "╔═══════════════════════════════════════════════╗"
	@echo "║   Starting ZK Bisection Fault Proof System    ║"
	@echo "╚═══════════════════════════════════════════════╝"
	@echo ""
	@# Create .env if not exists
	@if [ ! -f $(ENV_FILE) ]; then \
		cp env.example $(ENV_FILE); \
	fi
	@# Check SP1 mode and auto-build ELF if needed
	@SP1_MODE=$$(grep "^SP1_PROVER=" $(ENV_FILE) 2>/dev/null | cut -d= -f2 | tr -d ' '); \
	if [ "$$SP1_MODE" = "true" ] || [ "$$SP1_MODE" = "1" ]; then \
		echo "[0/4] SP1 mode detected, checking ELF..."; \
		if [ ! -f $(ELF_FILE) ]; then \
			echo "      Building ELF (first time only)..."; \
			$(MAKE) build-elf || exit 1; \
		fi; \
		echo "      ✓ ELF ready: $(ELF_FILE)"; \
		sed -i.bak "s|^ELF_PATH=.*|ELF_PATH=/app/elf/block-verify-program|" $(ENV_FILE) && rm -f $(ENV_FILE).bak; \
		sed -i.bak "s|^# ELF_PATH=.*|ELF_PATH=/app/elf/block-verify-program|" $(ENV_FILE) && rm -f $(ENV_FILE).bak; \
	else \
		echo "[0/4] Mock mode (SP1_PROVER=false)"; \
	fi
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
	@# Step 2: Deploy contracts
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
	@SP1_MODE=$$(grep "^SP1_PROVER=" $(ENV_FILE) 2>/dev/null | cut -d= -f2 | tr -d ' '); \
	if [ "$$SP1_MODE" = "true" ] || [ "$$SP1_MODE" = "1" ]; then \
		echo "  SP1 Mode:       SP1 Network (real ZK proof)"; \
	else \
		echo "  SP1 Mode:       Mock (fast testing)"; \
	fi
	@echo "  Benchmark TPS:  $${BENCHMARK_TPS:-1}"
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
	@rm -rf $(ELF_DIR)/
	@rm -f $(ENV_FILE)
	@echo "✓ Clean complete"
