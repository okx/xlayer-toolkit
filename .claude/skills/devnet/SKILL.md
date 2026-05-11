---
name: devnet
description: Bring up the X Layer devnet (OP Stack local test environment) end to end — verify repo paths in example.env, build images via devnet/init.sh, start services with ./0-all.sh, then confirm the sequencer is producing blocks on port 8123. Use when the user asks to start / run / deploy / bring up the devnet, or to restart / verify the local OP Stack environment.
---

# Devnet — X Layer local OP Stack bring-up

This skill brings up the local OP Stack devnet in `<repo-root>/devnet`, confirms repo paths are wired up in `example.env`, builds images, starts services, and verifies the L2 sequencer is producing blocks.

See `devnet/README.md` for full background. The flow here is the "first-time setup then run" path, not `make run`.

## 0. Working directory

All commands run from `<repo-root>/devnet`. Resolve the repo root with `git rev-parse --show-toplevel` and `cd "$(git rev-parse --show-toplevel)/devnet"` before each step (or run once at the start). Never edit `.env` directly — edit `example.env` and run `./clean.sh` to sync.

## 1. Check repo paths in `example.env`

Before building, verify that the *local repo directories* required for local image builds are configured. If `SKIP_*_BUILD=true` for a component, its path is not needed; if `SKIP_*_BUILD=false` the corresponding `*_LOCAL_DIRECTORY` must be an absolute path to a cloned repo.

Components and their variables in `example.env`:

| Component | Skip flag | Local dir variable | Upstream repo |
|-----------|-----------|---------------------|----------------|
| OP Stack | `SKIP_OP_STACK_BUILD` | `OP_STACK_LOCAL_DIRECTORY` | https://github.com/okx/optimism |
| OP Contracts | `SKIP_OP_CONTRACTS_BUILD` | (uses `OP_STACK_LOCAL_DIRECTORY`) | same as above |
| OP Geth | `SKIP_OP_GETH_BUILD` | `OP_GETH_LOCAL_DIRECTORY` | https://github.com/okx/op-geth |
| OP Reth | `SKIP_OP_RETH_BUILD` | `OP_RETH_LOCAL_DIRECTORY` | https://github.com/okx/reth |
| OP Succinct | `SKIP_OP_SUCCINCT_BUILD` | `OP_SUCCINCT_LOCAL_DIRECTORY` | (optional, only if `PROOF_ENGINE=op-succinct`) |
| Kailua | `SKIP_KAILUA_BUILD` | `KAILUA_LOCAL_DIRECTORY` | (optional, only if `PROOF_ENGINE=kailua`) |

Recommended check (run from `<repo-root>/devnet`):

```bash
grep -E '^(SKIP_[A-Z_]+_BUILD|[A-Z_]+_LOCAL_DIRECTORY)=' example.env
```

For every `SKIP_X_BUILD=false`, confirm the matching `X_LOCAL_DIRECTORY` is a non-empty absolute path that exists on disk. If any required path is missing or empty, **stop and prompt the user** with a clear list of which variables need to be filled in, e.g.:

> `OP_RETH_LOCAL_DIRECTORY` is empty but `SKIP_OP_RETH_BUILD=false`. Please set it to the absolute path of your local `okx/reth` clone in `example.env`, then re-run this skill.

Do not attempt to guess paths or clone repositories automatically.

Also confirm the sequencer / RPC mode combination matches the user's intent (e.g. `SEQ_TYPE=reth` / `RPC_TYPE=reth` vs `geth`). If unclear, ask.

## 2. Build images — `./init.sh`

Once `example.env` is correct:

```bash
cd "$(git rev-parse --show-toplevel)/devnet"
./clean.sh        # sync example.env -> .env and stop any stale containers
./init.sh         # build Docker images for all components with SKIP_*_BUILD=false
```

Notes:
- `init.sh` can take a long time (tens of minutes) depending on which components are being built locally. Run in the foreground and stream output so the user can see progress.
- If `init.sh` fails, surface the failing step (usually a Docker build) and stop — do not proceed to start services.
- Re-run `init.sh` only when code changes require rebuilt images.

## 3. Start services — `./0-all.sh`

```bash
cd "$(git rev-parse --show-toplevel)/devnet"
./0-all.sh
```

This chains `1-start-l1.sh` → `2-deploy-op-contracts.sh` → `3-op-init.sh` → `4-op-start-service.sh` (and `5-*` / `6-*` if the corresponding proof engines are enabled). Expect it to take several minutes; watch for errors in contract deployment and op-geth/op-reth init.

## 4. Verify block production on port 8123

After `0-all.sh` exits successfully, confirm the L2 sequencer RPC is up and blocks are advancing. Port `8123` is the `op-geth-seq` / sequencer RPC (see the Service Ports table in `devnet/README.md`).

### 4.1 Port is listening

```bash
# macOS
lsof -iTCP:8123 -sTCP:LISTEN -n -P
# or
nc -z localhost 8123 && echo "8123 open" || echo "8123 closed"
```

If the port is not listening, inspect container state:

```bash
cd "$(git rev-parse --show-toplevel)/devnet"
docker compose ps
docker compose logs --tail=200 op-geth-seq
```

Report the failing container and stop — do not claim success.

### 4.2 Block number is increasing

Query `eth_blockNumber` several times with a short gap and confirm the value strictly increases. Use `curl` (no extra tooling required):

```bash
for i in 1 2 3 4 5; do
  curl -s -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    http://localhost:8123 \
    | sed -E 's/.*"result":"(0x[0-9a-fA-F]+)".*/\1/'
  sleep 2
done
```

Pass criteria:
- Every response is a valid `0x...` hex block number (not an error object).
- The decimal value strictly increases across samples (at least one increment over ~10 seconds).

If the value does not change, the sequencer is not producing blocks. Check `docker compose logs op-geth-seq` and `docker compose logs op-node` (or `op-seq`), report the symptom, and stop. Do not report the devnet as healthy.

### 4.3 Reporting

When all three checks pass (port listening, valid block numbers, strictly increasing), report concisely:

> Devnet is up. Port 8123 listening. Block number advanced from `<n0>` to `<nN>` over `<seconds>`s.

## 5. Things to avoid

- Do not edit `.env` directly — always edit `example.env`, then `./clean.sh`.
- Do not run `./init.sh` repeatedly "just in case" — it is slow and destructive to image caches.
- Do not skip the block-number verification and assume success from port 8123 being open; a stuck sequencer will still hold the port.
- Do not invent repo paths or auto-clone missing repositories — prompt the user instead.
- Do not print or commit any private keys or funded test-account secrets from `devnet/` configs.
