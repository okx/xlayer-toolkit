---
name: sa-benchmark
description: Run the SA-Benchmark (Smart Account / OKX Pay ERC-4337) stress test using the "Old Method" — `./1-setup.sh` (TypeScript deploy + clone/build polycli) followed by `./2-bench.sh` (polycli loadtest erc4337). Use when the user asks to run SA-Benchmark, benchmark OKX Pay / Smart Account / ERC-4337, or run polycli erc4337 loadtest. The SA-Benchmark project lives outside this repo; its absolute path is stored in a per-skill config file and can be changed at any time.
---

# SA-Benchmark — Smart Account / OKX Pay ERC-4337 loadtest

This skill runs the **Old Method** from the SA-Benchmark project README: TypeScript contract deploy + initial UserOperation, followed by a Go `polycli loadtest erc4337` run. The SA-Benchmark repo is external to this toolkit, so its absolute path must be configured before the skill can run.

See `<SA_BENCHMARK_DIR>/README.md` in the target repo for full background. The relevant scripts are `1-setup.sh` and `2-bench.sh` in that directory's root.

## 0. Locate / configure the SA-Benchmark directory

The SA-Benchmark directory is **not** inside this repo. The skill stores its absolute path in:

```
<repo-root>/.claude/skills/sa-benchmark/config.env
```

Contents (single line):

```
SA_BENCHMARK_DIR=/absolute/path/to/SA-Benchmark
```

### First-time initialization

1. Resolve the config path: `CONFIG_FILE="$(git rev-parse --show-toplevel)/.claude/skills/sa-benchmark/config.env"`.
2. If `CONFIG_FILE` does **not** exist, or exists but `SA_BENCHMARK_DIR` is empty / missing:
   - **Stop and prompt the user**. Ask for the absolute path to their local SA-Benchmark clone (e.g. `/Users/oker/go/bin/code/ethereum/SA-Benchmark`). Do not guess, do not `find`, do not auto-clone.
   - Once the user replies, validate that the path is absolute, exists, is a directory, and contains both `1-setup.sh` and `2-bench.sh` and an `example.env` file. If any check fails, report the exact problem and re-prompt.
   - Write the config file with `SA_BENCHMARK_DIR=<path>` and confirm.
3. If `CONFIG_FILE` exists and `SA_BENCHMARK_DIR` points at a valid directory, proceed.

### Changing the directory later

The user can change the path at any time by saying things like "change SA-Benchmark dir to X", "point SA-Benchmark at /new/path", or "reconfigure SA-Benchmark". When that happens:
1. Validate the new path (same checks as first-time init).
2. Overwrite `config.env` with the new `SA_BENCHMARK_DIR=...`.
3. Confirm the updated value back to the user. Do **not** delete or clean up the previous directory.

Never edit the SA-Benchmark project's `.env` or scripts to change its location — the path is a Claude-side config only.

## 1. Prepare `.env` in the SA-Benchmark directory

All remaining steps run with `cd "$SA_BENCHMARK_DIR"`.

1. If `.env` does not exist, copy it from the template: `cp example.env .env`. Do not overwrite an existing `.env`.
2. Verify the required fields for the Old Method are populated in `.env`:
   - `PRIVATE_KEY` — funded L2 account (must not be empty / default)
   - `LOCAL_RPC_URL` — L2 RPC, typically `http://127.0.0.1:8123` when running against the local devnet
   - `CARD_ENABLE` — must be `false` (or unset). The Old Method is the ERC4337 + polycli path; `CARD_ENABLE=true` switches `1-setup.sh` / `2-bench.sh` to the Card Claim path, which is **not** what this skill runs.
   - `POLYCLI_REPO`, `POLYCLI_BRANCH` — used by `1-setup.sh` to clone and build polycli
   - `GAS_PRICE`, `CALLDATA_FILE`, `CALLDATA_SIZE`, `TOTAL_UOP`, `BATCH_SIZE`, `CONCURRENCY`, `RATE_LIMIT`, `CALLDATA_TYPE`, `VERIFIER_TYPE` — required by `1-setup.sh`'s pre-flight check; empty values will make the script exit.
3. If any required field is missing, **stop and list them** for the user. Only print each variable's *name*, never its value — secrets like `PRIVATE_KEY` must not be echoed.

Quick check (safe — prints only variable *names* whose values are empty):

```bash
cd "$SA_BENCHMARK_DIR"
[ -f .env ] || cp example.env .env
set -a; . ./.env; set +a
for v in PRIVATE_KEY LOCAL_RPC_URL POLYCLI_REPO POLYCLI_BRANCH GAS_PRICE \
         CALLDATA_FILE CALLDATA_SIZE TOTAL_UOP BATCH_SIZE CONCURRENCY \
         RATE_LIMIT CALLDATA_TYPE VERIFIER_TYPE; do
  [ -z "${!v}" ] && echo "MISSING: $v"
done
[ "${CARD_ENABLE:-false}" = "true" ] && echo "WARNING: CARD_ENABLE=true switches to the Card path, not the Old Method"
```

If the user wants the benchmark to target this toolkit's local devnet, `LOCAL_RPC_URL` should be `http://127.0.0.1:8123` and the devnet must already be up (see the `devnet` skill). Do not start the devnet from inside this skill — if the user wants both, suggest running the `devnet` skill first.

## 2. Setup — `./1-setup.sh`

```bash
cd "$SA_BENCHMARK_DIR"
./1-setup.sh
```

What it does (Old Method branch, i.e. `CARD_ENABLE=false`):
- Clones or updates `POLYCLI_REPO` at `POLYCLI_BRANCH`, then runs `make install` so the `polycli` binary lands in `~/go/bin`.
- `yarn` to install Node dependencies.
- `yarn run deploy` to deploy / attach to the Smart Account + OKX Pay contracts.
- `yarn run senduop:local` to send the initial UserOperation that counterfactually deploys sender accounts and funds bundlers.

Notes:
- The setup can take several minutes (Go build + Node install + on-chain deploys). Stream output; don't background it.
- If `1-setup.sh` fails, surface the failing step and **stop** — do not proceed to `2-bench.sh`. Re-running setup after the user fixes the underlying issue is safe.
- The script populates contract addresses (`ENTRYPOINT`, `ACCOUNT_FACTORY`, `PAY`, `TEST_ERC20`, `WEBAUTHN_VALIDATOR`, …) in `.env`; `2-bench.sh` reads them. If any of those are empty after setup, setup did not finish — investigate before benching.

## 3. Benchmark — `./2-bench.sh`

```bash
cd "$SA_BENCHMARK_DIR"
./2-bench.sh
```

Behavior (Old Method branch):
- Prints the test parameters (TOTAL_UOP, BATCH_SIZE, CONCURRENCY, RATE_LIMIT, CALLDATA_TYPE).
- Writes raw output to `result_<YYYYMMDD_HHMM>.out` in the SA-Benchmark directory.
- Runs `polycli loadtest erc4337` with the contract addresses set up in step 2.
- At the end, strips ANSI escapes, greps the last `tps=...` line, and prints `Final TPS: <value>`.

Heads-up to the user (optional, only mention if the benchmark is expected to run long):
- Perf profile capture: `curl http://localhost:6060/debug/pprof/profile?seconds=120 > prof_<timestamp>.bin`
- Sequencer log monitor: `docker logs xlayer-seq --tail 10 -f 2>&1 | grep TotalDuration-batch`

## 4. Reporting

After `2-bench.sh` exits:
1. Identify the newest `result_*.out` in `$SA_BENCHMARK_DIR` (the one the script just wrote).
2. Extract the final TPS. Prefer the line `TPS: <value>` appended at the end of the file; fall back to the last `tps=<value>` match.
3. Report concisely to the user, e.g.:
   > SA-Benchmark finished. Final TPS: `<value>`. Full log: `<SA_BENCHMARK_DIR>/result_<timestamp>.out`.

If `Final TPS` is missing or empty, the loadtest did not complete cleanly — do not claim success. Summarize the tail of the result file (last ~20 lines) and any error lines you can see.

## 5. Things to avoid

- **Never** print, log, or commit `PRIVATE_KEY`, derived wallets, bundler private keys, or any value from `.env`. Reference fields by name only.
- Never clone the SA-Benchmark repo automatically. If the configured path is missing, prompt the user.
- Never run `./loadtest.sh` or `yarn deploy` directly from this skill — that is the "New Method" and is explicitly out of scope here.
- Never set `CARD_ENABLE=true` or run the card path; that is a different benchmark and not what this skill targets.
- Never run `2-bench.sh` before `1-setup.sh` succeeds; the contract addresses it reads from `.env` won't be populated.
- Do not delete or truncate previous `result_*.out` / `result_*.out.bak` files unless the user asks.
- Do not edit the SA-Benchmark project's files to hard-code paths or secrets — the directory path lives only in this skill's `config.env`.
