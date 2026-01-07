# ============================================================================
# Multi-stage Docker build for RAILGUN Test
# ============================================================================
# This Dockerfile expects Kohaku source to be mounted at build time
# Usage: docker build --build-context kohaku=/path/to/kohaku -t railgun-test .
# ============================================================================

# Stage 1: Build Kohaku from external source
FROM node:22-alpine AS kohaku-builder

WORKDIR /build

# Install build dependencies
RUN apk add --no-cache python3 make g++

# Install pnpm
RUN npm install -g pnpm

# Copy Kohaku source (from build context)
COPY --from=kohaku . /build/kohaku

WORKDIR /build/kohaku

# Modify circuit-artifacts URL in railgun package
RUN cd packages/railgun && \
    sed -i 's|https://npm.railgun.org/railgun-community-circuit-artifacts-0.0.1.tgz|https://ipfs-lb.com/ipfs/QmPvs6Lws1MS4CTMAQ6P3WfyFpWFKGu7o6cSbWCu3vgXLW/railgun-circuit-test-artifacts-0.0.1.tgz|g' package.json

# Install and build with network retries
RUN pnpm install --no-frozen-lockfile \
    --fetch-retries=5 \
    --fetch-retry-mintimeout=20000 \
    --fetch-retry-maxtimeout=120000 && \
    pnpm -r build || true

# Verify railgun package was built
RUN test -f packages/railgun/dist/index.d.ts || (echo "❌ Railgun build failed" && exit 1)

# Pack the railgun package
RUN cd packages/railgun && \
    pnpm pack && \
    mv *.tgz /build/kohaku-railgun.tgz

# ============================================================================
# Stage 2: Runtime image
# ============================================================================
FROM node:22-alpine

WORKDIR /app

# Install pnpm
RUN npm install -g pnpm

# Copy built Kohaku package from builder
COPY --from=kohaku-builder /build/kohaku-railgun.tgz ./kohaku-railgun.tgz

# Copy application files
COPY package.json ./
COPY test-kohaku.ts ./

# Install test dependencies (using local kohaku package)
# Note: Need devDependencies (tsx, typescript) to run tests
RUN pnpm install --no-frozen-lockfile

# Note: Circuit artifacts (~500MB) will be downloaded on first run
# This avoids build timeout issues with slow networks
# Artifacts are cached in the container's node_modules after first download

# Cleanup
RUN rm -f kohaku-railgun.tgz

# Set default environment variables
ENV CHAIN_ID=195
ENV RPC_URL=http://host.docker.internal:8123

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD node -e "console.log('OK')" || exit 1

ENTRYPOINT ["pnpm", "test:kohaku"]

