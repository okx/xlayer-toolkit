# demo DEX - Multi-stage Dockerfile
# Builds all demo services and programs

# ============================================================================
# Base Go builder
# ============================================================================
FROM golang:1.21-alpine AS builder

RUN apk add --no-cache git make

WORKDIR /app

# Copy go mod files
COPY go.mod ./
RUN go mod download

# Copy source code
COPY . .

# Build node (Sequencer + RPC only)
RUN go build -o /out/node ./node/cmd/node/...

# Build demo-batcher (Standalone)
RUN go build -o /out/demo-batcher ./node/cmd/batcher/...

# Build demo-proposer (Standalone)
RUN go build -o /out/demo-proposer ./node/cmd/proposer/...

# Build demo-challenger (Standalone)
RUN go build -o /out/demo-challenger ./node/cmd/challenger/...

# Build program (for Cannon)
RUN go build -o /out/program ./program/...

# ============================================================================
# demo Node - Sequencer + RPC
# ============================================================================
FROM alpine:3.19 AS node

RUN apk add --no-cache ca-certificates wget

COPY --from=builder /out/node /usr/local/bin/node

ENV BLOCK_TIME=2s
ENV BATCH_SIZE=10
ENV RPC_ADDR=:8546

EXPOSE 8546

CMD ["sh", "-c", "node -block-time=$BLOCK_TIME -batch-size=$BATCH_SIZE -rpc-addr=$RPC_ADDR"]

# ============================================================================
# demo Program - Cannon Fault Proof (MIPS target)
# ============================================================================
FROM alpine:3.19 AS program

RUN apk add --no-cache ca-certificates

COPY --from=builder /out/program /usr/local/bin/program

# This is used for preimage generation and local testing
# In production, this would be compiled to MIPS for Cannon VM
CMD ["program"]

# ============================================================================
# Batcher Service (Standalone)
# ============================================================================
FROM alpine:3.19 AS batcher

RUN apk add --no-cache ca-certificates curl

COPY --from=builder /out/demo-batcher /usr/local/bin/demo-batcher

ENV L1_RPC=http://anvil:8545
ENV DEMO_RPC=http://node:8546
ENV BATCH_INBOX_ADDRESS=
ENV SUBMIT_INTERVAL=10s

CMD ["sh", "-c", "demo-batcher -l1-rpc=$L1_RPC -demo-rpc=$DEMO_RPC -batch-inbox=$BATCH_INBOX_ADDRESS -submit-interval=$SUBMIT_INTERVAL"]

# ============================================================================
# Proposer Service (Standalone)
# ============================================================================
FROM alpine:3.19 AS proposer

RUN apk add --no-cache ca-certificates curl

COPY --from=builder /out/demo-proposer /usr/local/bin/demo-proposer

ENV L1_RPC=http://anvil:8545
ENV DEMO_RPC=http://node:8546
ENV OUTPUT_ORACLE_ADDRESS=
ENV SUBMIT_INTERVAL=10s

CMD ["sh", "-c", "demo-proposer -l1-rpc=$L1_RPC -demo-rpc=$DEMO_RPC -output-oracle=$OUTPUT_ORACLE_ADDRESS -submit-interval=$SUBMIT_INTERVAL"]

# ============================================================================
# Challenger Service (Standalone) with Cannon support
# Build cannon inside the Dockerfile to avoid dependency issues
# ============================================================================
FROM golang:1.23-bookworm AS cannon-builder

RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone --depth 1 --branch develop https://github.com/ethereum-optimism/optimism.git optimism

WORKDIR /build/optimism
ENV GOTOOLCHAIN=auto
RUN go build -o /cannon ./cannon/

FROM debian:bookworm-slim AS challenger

RUN apt-get update && apt-get install -y ca-certificates curl && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/demo-challenger /usr/local/bin/demo-challenger
# Copy cannon binary built in this Dockerfile
COPY --from=cannon-builder /cannon /usr/local/bin/cannon

# Create cannon work directory
RUN mkdir -p /cannon-work

ENV L1_RPC=http://anvil:8545
ENV DEMO_RPC=http://node:8546
ENV OUTPUT_ORACLE_ADDRESS=
ENV DISPUTE_GAME_FACTORY_ADDRESS=
ENV PREIMAGE_ORACLE_ADDRESS=
ENV MIPS_ADDRESS=
ENV POLL_INTERVAL=10s
# Cannon configuration
ENV CANNON_MODE=local
ENV CANNON_PATH=/usr/local/bin/cannon
ENV PROGRAM_PATH=/app/bin/program.elf
ENV CANNON_WORK_DIR=/cannon-work

CMD ["sh", "-c", "demo-challenger -l1-rpc=$L1_RPC -demo-rpc=$DEMO_RPC -output-oracle=$OUTPUT_ORACLE_ADDRESS -dispute-factory=$DISPUTE_GAME_FACTORY_ADDRESS -poll-interval=$POLL_INTERVAL -cannon-path=$CANNON_PATH -program-path=$PROGRAM_PATH -cannon-work-dir=$CANNON_WORK_DIR"]

# ============================================================================
# Test Runner
# ============================================================================
FROM golang:1.21-alpine AS test-runner

RUN apk add --no-cache ca-certificates git make curl

WORKDIR /app
COPY . .
RUN go mod download

# Use sh as entrypoint to allow flexible commands
ENTRYPOINT ["/bin/sh", "-c"]
CMD ["go test -v ./test/..."]
