# ==============================================================================
# RAILGUN Test Wallet Dockerfile
# ==============================================================================
# Purpose: Run RAILGUN wallet tests in Node.js v16 environment to avoid
#          leveldown compatibility issues with Node.js v18+
# ==============================================================================

FROM node:16-bullseye

# Install build dependencies for native modules (leveldown, etc.)
RUN apt-get update && apt-get install -y \
    python3 \
    make \
    g++ \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy package files first for better layer caching
COPY package*.json ./
COPY yarn.lock* ./
COPY tsconfig.json ./

# Install dependencies (will compile native modules for Node.js v16)
RUN if [ -f yarn.lock ]; then \
      yarn install --frozen-lockfile --network-timeout 300000; \
    elif [ -f package-lock.json ]; then \
      npm ci --legacy-peer-deps; \
    else \
      npm install --legacy-peer-deps; \
    fi

# Copy source code and contracts
COPY . .

# Default command: run the test script
CMD ["npx", "tsx", "test-basic.ts"]

