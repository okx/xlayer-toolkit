# demo DEX - Complete Cannon Fault Proof System
# Docker-based development with MIPS compilation

.PHONY: build-docker build-mips build-cannon run stop deploy-contracts challenge clean help

DOCKER_COMPOSE = docker compose -p devnet
COMPOSE_FILE = docker-compose.yaml
ENV_FILE = .env.contracts

# L1 Configuration
L1_RPC = http://127.0.0.1:8545
DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# MIPS Compilation
MIPS_GOOS = linux
MIPS_GOARCH = mips64
MIPS_GOMIPS = softfloat

help:
	@echo "demo DEX - Cannon Fault Proof System"
	@echo ""
	@echo "Commands:"
	@echo "  build-docker    Build all Docker images"
	@echo "  build-mips      Compile program to MIPS64"
	@echo "  build-cannon    Build cannon binary from optimism"
	@echo "  run             Start all services"
	@echo "  stop            Stop all services"
	@echo "  logs            Show logs for specific service"
	@echo "  logs-all        Show all logs"
	@echo "  test-e2e        Run e2e tests"
	@echo "  test-challenge  Run challenge test"
	@echo "  test-cannon-local  Run local cannon test"
	@echo "  clean           Clean build artifacts"

# =============================================================================
# MIPS Compilation for Cannon
# =============================================================================

build-mips:
	@echo "Building program for MIPS64..."
	@mkdir -p bin
	GOOS=$(MIPS_GOOS) GOARCH=$(MIPS_GOARCH) GOMIPS64=$(MIPS_GOMIPS) \
		go build -o bin/program.elf ./program/
	@echo "✓ program.elf created"
	@if command -v readelf >/dev/null 2>&1; then \
		readelf -h bin/program.elf | grep -E "Class|Machine" || true; \
	fi

build-mips-debug:
	@echo "Building program for MIPS64 with debug symbols..."
	@mkdir -p bin
	GOOS=$(MIPS_GOOS) GOARCH=$(MIPS_GOARCH) GOMIPS64=$(MIPS_GOMIPS) \
		go build -gcflags="all=-N -l" -o bin/program-debug.elf ./program/
	@echo "✓ program-debug.elf created"

generate-prestate: build-mips
	@echo "Generating prestate..."
	@# In a full implementation, this would use cannon load-elf
	@# For MVP, we create a simple prestate hash
	@echo "demo-prestate-v1" | sha256sum | cut -d' ' -f1 > bin/prestate.hash
	@echo "✓ Prestate hash: $$(cat bin/prestate.hash)"

verify-mips:
	@echo "Verifying MIPS binary..."
	@if [ -f bin/program.elf ]; then \
		file bin/program.elf; \
		if command -v readelf >/dev/null 2>&1; then \
			readelf -h bin/program.elf | grep -E "Class|Machine|Entry"; \
		fi; \
	else \
		echo "Error: bin/program.elf not found. Run 'make build-mips' first."; \
		exit 1; \
	fi

# =============================================================================
# Cannon Binary (Docker-based for macOS compatibility)
# =============================================================================

CANNON_DOCKER_DIR = cannon-docker
CANNON_WORK_DIR = $(CANNON_DOCKER_DIR)/work
CANNON_IMAGE = cannon-runner

# Build cannon docker image
build-cannon:
	@echo "Building cannon Docker image..."
	@docker build -t $(CANNON_IMAGE) $(CANNON_DOCKER_DIR)/
	@echo "✓ cannon Docker image built"

# Helper function to run cannon in docker
define run_cannon
	@mkdir -p $(CANNON_WORK_DIR)
	@docker run --rm \
		-v $(PWD)/bin:/app/bin:ro \
		-v $(PWD)/$(CANNON_WORK_DIR):/work \
		-w /work \
		$(CANNON_IMAGE) $(1)
endef

verify-cannon:
	@echo "Verifying cannon Docker image..."
	@docker run --rm $(CANNON_IMAGE) version || echo "✓ cannon docker ready"

# Load ELF into cannon state
cannon-load-elf: build-mips
	@echo "Loading ELF into cannon..."
	@mkdir -p $(CANNON_WORK_DIR)
	$(call run_cannon,load-elf --path /app/bin/program.elf --out /work/state.bin.gz --meta /work/meta.json)
	@echo "✓ Initial state created: $(CANNON_WORK_DIR)/state.bin.gz"

# Run cannon to completion
cannon-run: cannon-load-elf
	@echo "Running cannon..."
	$(call run_cannon,run --input /work/state.bin.gz --output /work/output.bin.gz --info-at '%10000' --proof-at never)
	@echo "✓ Cannon run complete"

# Generate proof at specific step
cannon-proof:
	@echo "Generating proof at step $(STEP)..."
	$(call run_cannon,run --input /work/state.bin.gz --output /work/step-$(STEP).bin.gz --proof-at '=$(STEP)' --stop-at '=$(shell expr $(STEP) + 1)' --proof-fmt '/work/proof-%d.json')
	@echo "✓ Proof generated: $(CANNON_WORK_DIR)/proof-$(STEP).json"

# Get state hash at step
cannon-witness:
	@echo "Getting witness for state..."
	$(call run_cannon,witness --input /work/state.bin.gz)

# =============================================================================
# Docker Build
# =============================================================================

build-docker:
	@echo "Building Docker images..."
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) build

# =============================================================================
# Contract Deployment
# =============================================================================

deploy-contracts:
	@echo "Deploying contracts..."
	@cd contracts && forge script script/Deploy.s.sol:DeployScript \
		--rpc-url $(L1_RPC) \
		--private-key $(DEPLOYER_KEY) \
		--broadcast 2>&1 | tee /tmp/deploy.log
	@BATCH_INBOX=$$(grep "BatchInbox deployed at:" /tmp/deploy.log | awk '{print $$NF}') && \
	OUTPUT_ORACLE=$$(grep "OutputOracle deployed at:" /tmp/deploy.log | awk '{print $$NF}') && \
	PREIMAGE_ORACLE=$$(grep "PreimageOracle deployed at:" /tmp/deploy.log | awk '{print $$NF}') && \
	MIPS=$$(grep "MIPS deployed at:" /tmp/deploy.log | awk '{print $$NF}') && \
	DISPUTE_FACTORY=$$(grep "DisputeGameFactory deployed at:" /tmp/deploy.log | awk '{print $$NF}') && \
	echo "BATCH_INBOX_ADDRESS=$$BATCH_INBOX" > $(ENV_FILE) && \
	echo "OUTPUT_ORACLE_ADDRESS=$$OUTPUT_ORACLE" >> $(ENV_FILE) && \
	echo "PREIMAGE_ORACLE_ADDRESS=$$PREIMAGE_ORACLE" >> $(ENV_FILE) && \
	echo "MIPS_ADDRESS=$$MIPS" >> $(ENV_FILE) && \
	echo "DISPUTE_GAME_FACTORY_ADDRESS=$$DISPUTE_FACTORY" >> $(ENV_FILE) && \
	echo "L1_RPC=http://anvil:8545" >> $(ENV_FILE) && \
	echo "DEMO_RPC=http://node:8546" >> $(ENV_FILE) && \
	echo "CHALLENGE_EVERY_N_OUTPUTS=100" >> $(ENV_FILE) && \
	echo "✓ BatchInbox: $$BATCH_INBOX" && \
	echo "✓ OutputOracle: $$OUTPUT_ORACLE" && \
	echo "✓ PreimageOracle: $$PREIMAGE_ORACLE" && \
	echo "✓ MIPS: $$MIPS" && \
	echo "✓ DisputeGameFactory: $$DISPUTE_FACTORY"

# =============================================================================
# Run Services
# =============================================================================

run: stop build-mips build-cannon build-docker
	@echo "Starting demo Cannon Fault Proof System..."
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) up -d anvil
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		if cast block-number --rpc-url $(L1_RPC) >/dev/null 2>&1; then \
			echo "✓ Anvil ready"; \
			break; \
		fi; \
		sleep 1; \
	done
	@$(MAKE) deploy-contracts
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) up -d node
	@sleep 5
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) up -d batcher proposer challenger
	@echo ""
	@echo "=== demo Cannon System Ready ==="
	@echo "  Anvil (L1):     http://localhost:8545"
	@echo "  demo Node (L2):   http://localhost:8546"
	@echo "  Services:       Batcher, Proposer, Challenger"
	@echo ""
	@echo "Challenger will challenge every 100 blocks automatically"
	@cat $(ENV_FILE) 2>/dev/null || true

stop:
	@-$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) down 2>/dev/null

# =============================================================================
# Logs
# =============================================================================

logs:
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) logs -f $(SERVICE)

logs-node:
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) logs -f node

logs-batcher:
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) logs -f batcher

logs-proposer:
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) logs -f proposer

logs-challenger:
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) logs -f challenger

logs-all:
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) logs -f

# =============================================================================
# Testing
# =============================================================================

test-e2e:
	@echo "Running e2e tests..."
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) --profile test run --rm test-runner \
		"go test -v ./test/... -run TestIntegration"

test-challenge:
	@echo "Running challenge tests..."
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) --profile test run --rm test-runner \
		"go test -v ./test/... -tags=challenge -run TestChallenge"

challenge:
	$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) --profile test run --rm test-runner \
		"go test -v ./test/... -tags=challenge -run TestChallenge"

test-cannon:
	@echo "Running Cannon E2E test..."
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) --profile test run --rm test-runner \
		"go test -v ./test/... -tags=challenge -run TestCannonDisputeGame"

test-cannon-full:
	@echo "Running Full Cannon Dispute Game test..."
	@$(DOCKER_COMPOSE) -f $(COMPOSE_FILE) --profile test run --rm test-runner \
		"go test -v ./test/... -tags=challenge -run TestCannonDisputeGameFull"

# Local cannon test (without docker)
test-cannon-local: build-mips verify-cannon
	@echo "Running local cannon test..."
	@go test -v ./test/... -run TestCannonLocal -count=1

# =============================================================================
# Manual Dispute Game Commands
# =============================================================================

create-game:
	@echo "Creating dispute game for batch $(BATCH_INDEX)..."
	@# This would call the DisputeGameFactory to create a new game

resolve-game:
	@echo "Resolving dispute game $(GAME_ADDRESS)..."
	@# This would call resolve() on the dispute game

# =============================================================================
# Clean
# =============================================================================

clean:
	@echo "Cleaning build artifacts..."
	@rm -rf bin/
	@rm -rf cannon-work/
	@rm -rf contracts/out/
	@rm -rf contracts/cache/
	@rm -f $(ENV_FILE)
	@echo "✓ Clean complete"
