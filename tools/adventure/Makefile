.PHONY: build lint erc20 native

# Configuration variables
CONFIG_FILE := ./testdata/config.json
INIT_AMOUNT := 100ETH

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

# Native Token stress test (init + bench)
native: build
	@echo "🚀 Starting Native Token test..."
	@adventure native-init $(INIT_AMOUNT) -f $(CONFIG_FILE)
	@sleep 10
	@adventure native-bench -f $(CONFIG_FILE)
	@echo "✅ Native Token test completed!"
