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
	@echo "OP_GETH_LOCAL_DIRECTORY: $$OP_GETH_LOCAL_DIRECTORY"
	@echo "OP_GETH_BRANCH: $(OP_GETH_BRANCH)"
	@if [ -n "$$OP_GETH_LOCAL_DIRECTORY" ]; then \
		echo "Using custom local directory: $$OP_GETH_LOCAL_DIRECTORY"; \
		cd "$$OP_GETH_LOCAL_DIRECTORY"; \
	else \
		echo "Using default submodule: ../op-geth"; \
		cd ../op-geth; \
	fi && \
	if [ -n "$(OP_GETH_BRANCH)" ]; then \
		echo "Switching to branch: $(OP_GETH_BRANCH)"; \
		git fetch origin && git checkout "$(OP_GETH_BRANCH)" && git pull origin "$(OP_GETH_BRANCH)"; \
	else \
		echo "Using current branch"; \
	fi && \
	echo "Running E2E tests..."; \
	MallocNanoZone=0 go test -count=1 -failfast -v -p 1 -timeout 600s ./test/e2e/...

.PHONY: test-geth-e2e
test-geth-e2e: stop
	@trap 'make stop' EXIT ERR INT TERM;
	@echo "OP_GETH_BRANCH: $(OP_GETH_BRANCH)"
	@echo "Running with SEQ_TYPE=geth RPC_TYPE=geth"
	@if [ -n "$(OP_GETH_BRANCH)" ]; then \
		echo "Running E2E tests with branch: $(OP_GETH_BRANCH)"; \
	else \
		echo "Running E2E tests with default branch"; \
	fi 
	SEQ_TYPE=geth RPC_TYPE=geth SKIP_OP_GETH_BUILD=false SKIP_OP_RETH_BUILD=true $(MAKE) run && sleep 10 && $(MAKE) run-geth-test && echo "✅ Geth E2E tests passed ✅"

.PHONY: run-reth-test
run-reth-test:
	@echo "Starting op-rpc2 for tests..."
	@./scripts/run-rpc2.sh
	@sleep 5
	@echo "XLAYER_RETH_LOCAL_DIRECTORY: $$XLAYER_RETH_LOCAL_DIRECTORY"
	@echo "XLAYER_RETH_BRANCH: $(XLAYER_RETH_BRANCH)"
	@if [ -n "$$XLAYER_RETH_LOCAL_DIRECTORY" ]; then \
		echo "Using custom local directory: $$XLAYER_RETH_LOCAL_DIRECTORY"; \
		cd "$$XLAYER_RETH_LOCAL_DIRECTORY"; \
	else \
		echo "Please set XLAYER_RETH_LOCAL_DIRECTORY in .env"; \
		exit 1; \
	fi && \
	if [ -n "$(XLAYER_RETH_BRANCH)" ]; then \
		echo "Switching to branch: $(XLAYER_RETH_BRANCH)"; \
		git fetch origin && git checkout "$(XLAYER_RETH_BRANCH)" && git pull origin "$(XLAYER_RETH_BRANCH)"; \
	else \
		echo "Using current branch"; \
	fi && \
	echo "Running Reth E2E tests..."; \
	cargo test -p xlayer-e2e-test -- --nocapture --test-threads=1

.PHONY: test-reth-e2e
test-reth-e2e: stop
	@trap 'make stop' EXIT ERR INT TERM;
	@echo "XLAYER_RETH_BRANCH: $(XLAYER_RETH_BRANCH)"
	@echo "Running with SEQ_TYPE=reth RPC_TYPE=reth"
	@if [ -n "$(XLAYER_RETH_BRANCH)" ]; then \
		echo "Running E2E tests with branch: $(XLAYER_RETH_BRANCH)"; \
	else \
		echo "Running E2E tests with default branch"; \
	fi
	@SEQ_TYPE=reth RPC_TYPE=reth SKIP_OP_RETH_BUILD=false SKIP_OP_GETH_BUILD=true FLASHBLOCK_ENABLED=true ENABLE_INNERTX_SEQ=true ENABLE_INNERTX_RPC=true $(MAKE) run && sleep 3 && $(MAKE) run-reth-test && echo "✅ Reth E2E tests passed ✅"