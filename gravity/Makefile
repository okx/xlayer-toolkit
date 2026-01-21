.PHONY: help prepare build start stop logs clean

.DEFAULT_GOAL := help

BINARY_PATH := gravity-sdk/target/release/gravity_node
LOG_FILE := gravity_node.out

help: ## Show help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

prepare: ## Clone repos and apply patches
	@[ -d "gravity-reth" ] || (git clone -b gravity-v0.4.1 https://github.com/Galxe/gravity-reth.git && cd gravity-reth && git apply ../0001-local-testing.patch)
	@[ -d "gravity-sdk" ] || git clone -b v0.4.1 https://github.com/Galxe/gravity-sdk.git && && cd gravity-sdk && git apply ../0001-local-testing-sdk.patch

build: ## Build gravity_node
	@cd gravity-sdk && \
		grep -qF '[patch."https://github.com/Galxe/gravity-reth"]' Cargo.toml || \
		(echo "" >> Cargo.toml && \
		 echo '[patch."https://github.com/Galxe/gravity-reth"]' >> Cargo.toml && \
		 echo 'greth = { path = "../gravity-reth" }' >> Cargo.toml) && \
		make gravity_node

start: ## Start gravity_node
	@bash scripts/start_mock.sh

stop: ## Stop gravity_node
	@lsof -ti :8545 | xargs kill -9 2>/dev/null || true

logs: ## View logs
	@tail -f $(LOG_FILE) 2>/dev/null || echo "Log file not found"

clean: stop ## Clean logs
	@rm -f $(LOG_FILE) gravity_node.pid
	@rm -rf gravity_node

