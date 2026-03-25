# mockteerpc

Standalone mock TeeRollup HTTP server for local development and testing.

---

## Mock TeeRollup Server

Simulates the `GET /v1/chain/confirmed_block_info` REST endpoint provided by a real TeeRollup service.

**Behavior:**
- Starts at block height 1000 (configurable)
- Increments height by a random delta in **[1, 50]** every second
- `appHash` = `keccak256(big-endian uint64 of height)`, `"0x"` prefix, 66 characters
- `blockHash` = `keccak256(appHash)`, `"0x"` prefix, 66 characters

---

## How to Run

### Option 1: Direct `go run`

```bash
cd tools/mockteerpc
go run ./cmd/mockteerpc

# Custom listen address and initial height
go run ./cmd/mockteerpc --addr :9000 --init-height 5000

# 30% error rate + max 500ms delay
go run ./cmd/mockteerpc --error-rate 0.3 --delay 500ms
```

### Option 2: Build then run

```bash
cd tools/mockteerpc
make build
./bin/mockteerpc --addr :8090
```

### Option 3: Docker

```bash
cd tools/mockteerpc

# Build image
make docker-build

# Run container (exposes :8090)
make docker-run

# Custom flags
docker run --rm -p 9000:9000 mockteerpc:latest --addr :9000 --init-height 5000
```

Startup output example:
```
mock TeeRollup server listening on :8090
initial height: 1000
error rate:     0.0%
max delay:      1s
endpoint: GET /v1/chain/confirmed_block_info

tick: height=1023 delta=23
tick: height=1058 delta=35
...
```

---

## curl Testing

```bash
# Query current confirmed block info
curl -s http://localhost:8090/v1/chain/confirmed_block_info | jq .
```

Example response:
```json
{
  "code": 0,
  "message": "OK",
  "data": {
    "height": 1023,
    "appHash": "0x3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b",
    "blockHash": "0x1234abcd..."
  }
}
```

### Observe height growth continuously

```bash
watch -n 0.5 'curl -s http://localhost:8090/v1/chain/confirmed_block_info | jq .data'
```

---

## Usage in Tests

```go
import mockteerpc "github.com/okx/xlayer-toolkit/tools/mockteerpc"

func TestMyFeature(t *testing.T) {
    srv := mockteerpc.NewTeeRollupServer(t)  // t.Cleanup closes automatically

    baseURL := srv.Addr()  // e.g. "http://127.0.0.1:12345"

    height, appHash, blockHash := srv.CurrentInfo()
    _ = height
    _ = appHash
    _ = blockHash
}
```

---

## CLI flags

| Flag           | Default | Description                                                              |
|----------------|---------|--------------------------------------------------------------------------|
| `--addr`       | `:8090` | Listen address                                                           |
| `--init-height`| `1000`  | Initial block height                                                     |
| `--error-rate` | `0`     | Error response probability [0.0, 1.0], 0 means no errors                |
| `--delay`      | `1s`    | Maximum random response delay, actual delay is random in [0, delay]     |

---

## Makefile targets

| Target         | Description                        |
|----------------|------------------------------------|
| `make build`   | Build binary to `bin/mockteerpc`   |
| `make run`     | Run via `go run`                   |
| `make test`    | Run all tests                      |
| `make docker-build` | Build Docker image            |
| `make docker-run`   | Run Docker container on :8090 |
| `make clean`   | Remove `bin/` directory            |
