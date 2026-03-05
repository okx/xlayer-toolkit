# syntax=docker/dockerfile:1
# ─── Stage 1: builder ────────────────────────────────────────────────────────
FROM rust:slim-bookworm AS builder

RUN apt-get update && apt-get install -y \
    curl git pkg-config libssl-dev protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/root/.sp1/bin:/root/.cargo/bin:${PATH}"
RUN curl -L https://sp1.succinct.xyz | bash
RUN sp1up --version v6.0.2

# ── Copy shared benchmark utils (path must match script/Cargo.toml) ──────────
COPY utils/ /utils/

WORKDIR /fibonacci

# ── Step 1: copy guest + deps (rarely change) → compile ELF ──────────────────
COPY sp1/fibonacci/Cargo.toml .
COPY sp1/fibonacci/lib/ lib/
COPY sp1/fibonacci/program/ program/
COPY sp1/fibonacci/script/Cargo.toml script/Cargo.toml
COPY sp1/fibonacci/script/build.rs script/build.rs
RUN mkdir -p script/src/bin && echo 'fn main() {}' > script/src/bin/main.rs
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/fibonacci/target \
    cargo build --release --bin fibonacci 2>/dev/null; true

# ── Step 2: copy host source (changes often) → rebuild host only ─────────────
COPY sp1/fibonacci/script/src/ script/src/
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/fibonacci/target \
    touch script/src/bin/main.rs && \
    cargo build --release --bin fibonacci && \
    cp target/release/fibonacci /fibonacci-bin

# ─── Stage 2: runner (minimal image) ─────────────────────────────────────────
FROM debian:bookworm-slim AS runner
RUN apt-get update && apt-get install -y ca-certificates libssl3 curl \
    && curl -fsSL https://get.docker.com | sh \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /fibonacci
COPY --from=builder /fibonacci-bin ./fibonacci
ENTRYPOINT ["./fibonacci"]
CMD ["--prove", "--n", "20", "--mode", "core"]
