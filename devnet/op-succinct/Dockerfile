# syntax=docker/dockerfile:1.4

# Chef stage: Prepare dependency recipe
FROM lukemathwalker/cargo-chef:latest-rust-1 AS chef
WORKDIR /app

# Install required dependencies
RUN apt-get update && apt-get install -y \
    clang \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Install SP1
RUN curl -L https://sp1.succinct.xyz | bash && \
    ~/.sp1/bin/sp1up && \
    ~/.sp1/bin/cargo-prove prove --version

ENV PATH="/root/.sp1/bin:${PATH}"

# Install project's required Rust toolchain
COPY rust-toolchain.toml ./
RUN rustup show  # This will install the toolchain and components from rust-toolchain.toml

# Planner stage: Generate recipe.json
FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# Builder stage: Build dependencies then project
FROM chef AS builder

# Copy recipe and build dependencies (this layer will be cached)
COPY --from=planner /app/recipe.json recipe.json

RUN cargo chef cook --release --bin proposer --bin challenger --bin config --recipe-path recipe.json

# Copy source code and build binaries
COPY . .

# Build all binaries (dependencies already built, only project code will compile)
RUN cargo build --release --bin proposer && \
    cargo build --release --bin challenger && \
    cargo build --release --bin config

# Runtime stage - minimal image
FROM ubuntu:24.04 AS runtime

WORKDIR /app

# Install only necessary runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \ 
    && rm -rf /var/lib/apt/lists/*

# Copy all three binaries from build target directory
COPY --from=builder /app/target/release/proposer /usr/local/bin/
COPY --from=builder /app/target/release/challenger /usr/local/bin/
COPY --from=builder /app/target/release/config /usr/local/bin/

# Default command
CMD ["config"]
