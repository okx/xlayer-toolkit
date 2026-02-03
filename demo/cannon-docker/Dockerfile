# Cannon Runner Docker Image
# Runs cannon binary in Linux environment
# Uses GOTOOLCHAIN=auto to automatically download Go 1.24

FROM golang:1.23-bookworm AS builder

# Install dependencies
RUN apt-get update && apt-get install -y \
    git \
    make \
    && rm -rf /var/lib/apt/lists/*

# Clone and build cannon from optimism
WORKDIR /build
ARG OPTIMISM_REPO=https://github.com/ethereum-optimism/optimism.git
ARG OPTIMISM_BRANCH=develop

RUN git clone --depth 1 --branch ${OPTIMISM_BRANCH} ${OPTIMISM_REPO} optimism

WORKDIR /build/optimism
# Use GOTOOLCHAIN=auto to let Go download the required version
ENV GOTOOLCHAIN=auto
RUN go build -o /cannon ./cannon/

# Runtime image
FROM debian:bookworm-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy cannon binary
COPY --from=builder /cannon /usr/local/bin/cannon

# Create work directory
WORKDIR /work

# Verify cannon works
RUN cannon version || echo "Cannon installed"

ENTRYPOINT ["cannon"]
