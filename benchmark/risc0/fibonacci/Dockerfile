# syntax=docker/dockerfile:1
# ─── Stage 1: builder ────────────────────────────────────────────────────────
FROM rust:slim-bookworm AS builder

RUN apt-get update && apt-get install -y \
    curl git pkg-config libssl-dev libclang-dev protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/root/.risc0/bin:/root/.cargo/bin:${PATH}"
RUN curl -L https://risczero.com/install | bash
RUN rzup install

# ── Copy shared benchmark utils ──────────────────────────────────────────────
COPY utils/ /utils/

WORKDIR /fibonacci

# ── Step 1: copy workspace + guest + lib (rarely change) → compile guest ELF ─
COPY risc0/fibonacci/Cargo.toml .
COPY risc0/fibonacci/lib/ lib/
COPY risc0/fibonacci/methods/ methods/
COPY risc0/fibonacci/host/Cargo.toml host/Cargo.toml
RUN mkdir -p host/src && echo 'fn main() {}' > host/src/main.rs
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/fibonacci/target \
    cargo build --release --bin fibonacci-bench 2>/dev/null; true

# ── Step 2: copy host source (changes often) → rebuild host only ─────────────
COPY risc0/fibonacci/host/src/ host/src/
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/fibonacci/target \
    touch host/src/main.rs && \
    cargo build --release --bin fibonacci-bench && \
    cp target/release/fibonacci-bench /fibonacci-bench-bin

# ─── Stage 2: runner (minimal image) ─────────────────────────────────────────
FROM debian:bookworm-slim AS runner
RUN apt-get update && apt-get install -y ca-certificates libssl3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /fibonacci
COPY --from=builder /fibonacci-bench-bin ./fibonacci-bench
ENTRYPOINT ["./fibonacci-bench"]
CMD ["--prove", "--n", "20", "--mode", "composite"]
