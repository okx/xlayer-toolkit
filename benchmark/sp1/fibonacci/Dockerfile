# syntax=docker/dockerfile:1
# ─── Stage 1: builder ────────────────────────────────────────────────────────
FROM rust:slim-bookworm AS builder

RUN apt-get update && apt-get install -y \
    curl git pkg-config libssl-dev protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/root/.sp1/bin:/root/.cargo/bin:${PATH}"
RUN curl -L https://sp1.succinct.xyz | bash
RUN sp1up --version v6.0.2

WORKDIR /fibonacci
COPY . .
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/fibonacci/target \
    cargo build --release --bin fibonacci && \
    cp target/release/fibonacci /fibonacci-bin

# ─── Stage 2: runner (minimal image) ─────────────────────────────────────────
FROM debian:bookworm-slim AS runner
RUN apt-get update && apt-get install -y ca-certificates libssl3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /fibonacci
COPY --from=builder /fibonacci-bin ./fibonacci
ENTRYPOINT ["./fibonacci"]
CMD ["--prove", "--n", "20"]
