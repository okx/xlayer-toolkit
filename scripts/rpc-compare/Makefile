.PHONY: build run clean install start stop logs

# Build the binary
build:
	go build -o rpc-compare main.go

# Run directly
run:
	go run main.go

# Install to /usr/local/bin
install: build
	sudo cp rpc-compare /usr/local/bin/

# Clean build artifacts
clean:
	rm -f rpc-compare *.log

# Start in background
start:
	bash start.sh

# Show running process
status:
	ps aux | grep "[g]o run main.go\|rpc-compare" || echo "Not running"

# Stop background process
stop:
	pkill -f "go run main.go\|rpc-compare" || echo "No process to stop"

# Show logs
logs:
	tail -f compare.log

# View last 50 lines
tail:
	tail -n 50 compare.log

