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

.PHONY: min-run
min-run: stop
	@mkdir -p tmp
	@echo "🚀 Starting minimal run mode (without proposer/challenger/monitor)"
	@echo "OP_GETH_BRANCH: $(OP_GETH_BRANCH)"
	@if [ -n "$(OP_GETH_BRANCH)" ]; then \
		echo "Initializing with branch: $(OP_GETH_BRANCH)"; \
		MIN_RUN=true ./init.sh $(OP_GETH_BRANCH); \
	else \
		echo "Initializing with default branch"; \
		MIN_RUN=true ./init.sh; \
	fi
	MIN_RUN=true ./0-all.sh

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
		SEQ_TYPE=geth RPC_TYPE=geth SKIP_OP_GETH_BUILD=false SKIP_OP_RETH_BUILD=true $(MAKE) run && sleep 10 && $(MAKE) run-geth-test; \
	else \
		echo "Running E2E tests with default branch"; \
		SEQ_TYPE=geth RPC_TYPE=geth SKIP_OP_GETH_BUILD=false SKIP_OP_RETH_BUILD=true $(MAKE) run && sleep 10 && $(MAKE) run-geth-test; \
	fi && echo "✅ Geth E2E tests passed ✅"

.PHONY: run-reth-test
run-reth-test:
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
	cargo test -p xlayer-e2e-test -- --nocapture --test-threads=1

.PHONY: test-reth-e2e
test-reth-e2e: stop
	@trap 'make stop' EXIT ERR INT TERM;
	@echo "OP_RETH_BRANCH: $(OP_RETH_BRANCH)"
	@echo "Running with SEQ_TYPE=reth RPC_TYPE=reth"
	@if [ -n "$(OP_RETH_BRANCH)" ]; then \
		echo "Running E2E tests with branch: $(OP_RETH_BRANCH)"; \
		SEQ_TYPE=reth RPC_TYPE=reth SKIP_OP_RETH_BUILD=false SKIP_OP_GETH_BUILD=true $(MAKE) run && sleep 3 && $(MAKE) run-reth-test; \
	else \
		echo "Running E2E tests with default branch"; \
		SEQ_TYPE=reth RPC_TYPE=reth SKIP_OP_RETH_BUILD=false SKIP_OP_GETH_BUILD=true $(MAKE) run && sleep 3 && $(MAKE) run-reth-test; \
	fi && echo "✅ Reth E2E tests passed ✅"