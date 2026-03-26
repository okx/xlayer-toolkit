# mockteeprover

Standalone mock TEE Prover HTTP server for local development and testing.

---

## Mock TEE Prover Server

Simulates the TEE Prover task API used by `op-challenger`. Accepts prove requests, generates mock batch proofs with ECDSA signatures, and returns them after a configurable delay.

**Behavior:**
- `POST /task/` — creates a prove task, returns `taskId`
- `GET /task/{taskId}` — polls task status (`Running` → `Finished` after delay)
- `GET /health` — health check
- Admin endpoints for testing: `/admin/fail-next`, `/admin/never-finish`, `/admin/reset`, `/admin/stats`

**Proof generation:**
- Signs `keccak256(abi.encode(startBlockHash, startStateHash, endBlockHash, endStateHash, l2Block))` with the configured ECDSA key
- Returns ABI-encoded `BatchProof[]` matching `TeeDisputeGame.sol`

---

## How to Run

### Option 1: Direct `go run`

```bash
cd tools/mockteeprover

# Requires SIGNER_PRIVATE_KEY (the TEE signer key registered in TeeProofVerifier)
SIGNER_PRIVATE_KEY=0x... go run .

# Custom listen address and task delay
SIGNER_PRIVATE_KEY=0x... LISTEN_ADDR=:9000 TASK_DELAY=5s go run .
```

### Option 2: Docker

```bash
cd tools/mockteeprover
docker build -t mockteeprover:latest .
docker run --rm -p 8690:8690 -e SIGNER_PRIVATE_KEY=0x... mockteeprover:latest
```

---

## curl Testing

```bash
# Health check
curl -s http://localhost:8690/health | jq .

# Submit a prove task
curl -s -X POST http://localhost:8690/task/ \
  -H 'Content-Type: application/json' \
  -d '{
    "startBlkHeight": 100,
    "endBlkHeight": 200,
    "startBlkHash": "0x0000000000000000000000000000000000000000000000000000000000000001",
    "endBlkHash": "0x0000000000000000000000000000000000000000000000000000000000000002",
    "startBlkStateHash": "0x0000000000000000000000000000000000000000000000000000000000000003",
    "endBlkStateHash": "0x0000000000000000000000000000000000000000000000000000000000000004"
  }' | jq .

# Poll task status (replace TASK_ID)
curl -s http://localhost:8690/task/TASK_ID | jq .

# View stats
curl -s http://localhost:8690/admin/stats | jq .
```

---

## Environment Variables

| Variable             | Default  | Description                                              |
|----------------------|----------|----------------------------------------------------------|
| `SIGNER_PRIVATE_KEY` | required | ECDSA private key for signing batch proofs (hex, with or without 0x prefix) |
| `LISTEN_ADDR`        | `:8690`  | Listen address                                           |
| `TASK_DELAY`         | `2s`     | Time before a task transitions from Running to Finished  |

---

## Admin Endpoints

| Endpoint               | Method | Description                                      |
|------------------------|--------|--------------------------------------------------|
| `/admin/fail-next`     | POST   | Next created task will immediately fail (one-shot)|
| `/admin/never-finish`  | POST   | New tasks stay Running forever until reset       |
| `/admin/reset`         | POST   | Clear all control flags                          |
| `/admin/stats`         | GET    | Show submitted request count and control flags   |
