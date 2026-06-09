.PHONY: build lint erc20 gasless native io fib create

# Configuration variables
CONFIG_FILE := ./testdata/config.json
INIT_AMOUNT := 10000ETH
# Gasless bench scenario: approve | transfer (override: make gasless GASLESS_SCENARIO=approve)
GASLESS_SCENARIO := transfer

# Lint the code using golangci-lint
lint:
	@echo "Linting code..."
	@if command -v golangci-lint >/dev/null 2>&1; then \
		golangci-lint run ./...; \
	else \
		echo "⚠️  golangci-lint not found. Install it with:"; \
		echo "    go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest"; \
		echo "Or using basic go vet:"; \
		go vet ./...; \
	fi
	@echo "✅ Lint completed!"

# Build and install the adventure binary to Go bin directory
build: lint
	@echo "Building adventure..."
	@go build -o $$(go env GOPATH)/bin/adventure .
	@GOBIN=$$(go env GOPATH)/bin; \
	if [ -z "$$(go env GOPATH)" ]; then \
		GOBIN=$$HOME/go/bin; \
	fi; \
	echo "✅ Build completed! Binary: $$GOBIN/adventure"

# ERC20 stress test (init + bench)
erc20: build
	@echo "🚀 Starting ERC20 test..."
	@adventure erc20-init $(INIT_AMOUNT) -f $(CONFIG_FILE) 2>&1 | tee /tmp/erc20-init.log
	@sleep 10
	@adventure erc20-bench -f $(CONFIG_FILE) --contract $$(grep "ERC20 Address:" /tmp/erc20-init.log | awk '{print $$NF}')
	@echo "✅ ERC20 test completed!"

# Gasless ERC20 stress test (devnet, chain id 195): gasless-init deploys + whitelists an ERC20, then
# gasless-bench uses that ERC20 as both the approve and transfer token via --contract.
gasless: build
	@echo "🚀 Starting Gasless ERC20 test (scenario=$(GASLESS_SCENARIO))..."
	@adventure gasless-init -f $(CONFIG_FILE) 2>&1 | tee /tmp/gasless-init.log
	@sleep 10
	@adventure gasless-bench -f $(CONFIG_FILE) --scenario $(GASLESS_SCENARIO) --contract $$(grep -oE "ERC20=0x[0-9a-fA-F]{40}" /tmp/gasless-init.log | head -1 | cut -d= -f2)
	@echo "✅ Gasless ERC20 test completed!"

# Native Token stress test (init + bench)
native: build
	@echo "🚀 Starting Native Token test..."
	@adventure native-init $(INIT_AMOUNT) -f $(CONFIG_FILE)
	@sleep 10
	@adventure native-bench -f $(CONFIG_FILE)
	@echo "✅ Native Token test completed!"

io: build
	@echo "🚀 Starting IO test..."
	@adventure simulator-init $(INIT_AMOUNT) -f $(CONFIG_FILE)
	@sleep 10
	@adventure io-bench -f $(CONFIG_FILE)
	@echo "✅ IO test completed!"

fib: build
	@echo "🚀 Starting Fibonacci test..."
	@adventure simulator-init $(INIT_AMOUNT) -f $(CONFIG_FILE)
	@sleep 10
	@adventure fib-bench -f $(CONFIG_FILE)
	@echo "✅ Fibonacci test completed!"

create: build
	@echo "🚀 Starting create contract test..."
	@adventure native-init $(INIT_AMOUNT) -f $(CONFIG_FILE)
	@sleep 10
	@adventure create-bench -f $(CONFIG_FILE)
	@echo "✅ create contract test completed!"
