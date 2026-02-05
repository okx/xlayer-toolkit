# Build stage
FROM rust:1.85-bookworm AS builder

RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Cargo.toml Cargo.lock* ./
COPY crates ./crates
COPY bin ./bin
COPY programs ./programs

# Build all binaries (without sp1 feature - uses mock prover)
RUN cargo build --release --bin node --bin batcher --bin proposer --bin challenger

# =============================================================================
# Node (L2 sequencer with block production)
# =============================================================================
FROM debian:bookworm-slim AS node

RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/node /usr/local/bin/node

EXPOSE 8546

CMD ["node"]

# =============================================================================
# Batcher (submits block data to L1 BatchInbox)
# =============================================================================
FROM debian:bookworm-slim AS batcher

RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/batcher /usr/local/bin/batcher

CMD ["batcher"]

# =============================================================================
# Proposer
# =============================================================================
FROM debian:bookworm-slim AS proposer

RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/proposer /usr/local/bin/proposer

CMD ["proposer"]

# =============================================================================
# Challenger
# =============================================================================
FROM debian:bookworm-slim AS challenger

RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/challenger /usr/local/bin/challenger

CMD ["challenger"]
