-include .env
export

.PHONY: stop
stop:
	echo "Performing cleanup..."
	@rm -rf tmp
	@./clean.sh
	echo "Cleanup completed"

.PHONY: run
run: stop
	@mkdir -p tmp
	@echo "OP_GETH_BRANCH: $(OP_GETH_BRANCH)"
	@if [ -n "$(OP_GETH_BRANCH)" ]; then \
		echo "Initializing with branch: $(OP_GETH_BRANCH)"; \
		./init.sh $(OP_GETH_BRANCH); \
	else \
		echo "Initializing with default branch"; \
		./init.sh; \
	fi
	./0-all.sh

.PHONY: run-geth-test
run-geth-test:
	@echo "Setting up op-geth dependencies..."
	@cd ./scripts && ./setup-op-geth-test-deps.sh
	@echo "Running Geth E2E tests..."
	@cd ./op-geth && MallocNanoZone=0 go test -count=1 -failfast -v -p 1 -timeout 600s ./test/e2e/...

.PHONY: run-reth-test
run-reth-test:
	@if [ "$(ALL)" = "true" ]; then \
		echo "Starting op-rpc2 for comparison tests..."; \
		./scripts/run-rpc2.sh; \
		sleep 5; \
	fi
	@echo "OP_RETH_LOCAL_DIRECTORY: $$OP_RETH_LOCAL_DIRECTORY"
	@echo "OP_RETH_BRANCH: $(OP_RETH_BRANCH)"
	@if [ -n "$$OP_RETH_LOCAL_DIRECTORY" ]; then \
		echo "Using custom local directory: $$OP_RETH_LOCAL_DIRECTORY"; \
		cd "$$OP_RETH_LOCAL_DIRECTORY"; \
	else \
		echo "Please set OP_RETH_LOCAL_DIRECTORY in .env"; \
		exit 1; \
	fi && \
	if [ -n "$(OP_RETH_BRANCH)" ]; then \
		echo "Switching to branch: $(OP_RETH_BRANCH)"; \
		git fetch origin && git checkout "$(OP_RETH_BRANCH)" && git pull origin "$(OP_RETH_BRANCH)"; \
	else \
		echo "Using current branch"; \
	fi && \
	echo "Running Reth E2E tests..."; \
	cargo test -p xlayer-e2e-test --test e2e_tests -- --nocapture --test-threads=1; \
	echo "Running Reth flashblocks E2E tests..."; \
	sleep 3; \
	if [ "$(ALL)" = "true" ]; then \
		cargo test -p xlayer-e2e-test --test flashblocks_tests -- --include-ignored --nocapture --test-threads=1; \
	else \
		cargo test -p xlayer-e2e-test --test flashblocks_tests -- --nocapture --test-threads=1; \
	fi

.PHONY: run-reth-test-all
run-reth-test-all:
	@$(MAKE) run-reth-test ALL=true
