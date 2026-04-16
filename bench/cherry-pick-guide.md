# Cherry-Pick Guide — feature/kona-cl-hypothesis → new branch from main

> Generated 2026-04-16. Files categorised by purpose, with copy instructions.

---

## Quick instructions

```bash
# 1. Create the new branch from main
git checkout main && git pull
git checkout -b feature/kona-cl-bench

# 2. Copy files from the working tree of the old branch
#    (assumes the old branch worktree is at ~/Documents/xlayer/xlayer-toolkit
#     and you have it checked out in a second worktree or will switch back)
#
#    Easiest approach: stash/export from old branch, apply on new.

# Option A — bulk copy from old branch working tree:
OLD=~/Documents/xlayer/xlayer-toolkit   # path to old branch checkout
NEW=.                                    # you're on the new branch

# For each file listed below:
#   cp "$OLD/<path>" "$NEW/<path>"
# Then: git add <path> && git commit

# Option B — checkout individual files from the old branch:
git checkout feature/kona-cl-hypothesis -- <path>
# ⚠️  This pulls the COMMITTED version. For files with unstaged working-tree
#     edits (marked WT below), you must copy the file manually instead.
```

---

## Category 1 — Scripts (core bench system)

These are the bench orchestration scripts. **Must carry.**

| # | File | Source | Why carry |
|---|---|---|---|
| 1 | `bench/bench.sh` | WT (committed + unstaged edits) | Main orchestrator — CL switching, report generation, comparison |
| 2 | `bench/scripts/bench-adventure.sh` | WT (committed + unstaged edits) | Load test driver — adventure ERC20 sender |
| 3 | `bench/bench-orchestrate.sh` | Untracked | Multi-CL session orchestrator |
| 4 | `bench/scripts/generate-report.py` | Staged (new) | Report generator |
| 5 | `bench/scripts/generate-simple-report.py` | Staged (new) | Simplified report generator |
| 6 | `bench/scripts/simple-report.template.md` | Staged (new) | Report template |
| 7 | `bench/scripts/generate-phase-report.py` | Staged (new) | Phase-level report |
| 8 | `bench/scripts/compare-opt2.py` | Staged (new) | Opt-2 comparison script |
| 9 | `bench/scripts/fcu-tps-correlation.py` | Staged (new) | FCU-TPS correlation analysis |
| 10 | `bench/scripts/patch-avg-stats.py` | Staged (new) | Post-process avg stats |
| 11 | `bench/scripts/repair-500m-stats.py` | Staged (new) | Repair 500M gas stats |

**Copy method:** Files 1-2 have working-tree edits — copy manually from filesystem. File 3 is untracked — copy manually. Files 4-11 are staged — `git checkout feature/kona-cl-hypothesis -- <path>` works.

---

## Category 2 — Devnet configuration

Docker and deployment config. **Must carry.**

| # | File | Source | Why carry |
|---|---|---|---|
| 13 | `devnet/docker-compose.yml` | WT (committed + unstaged edits) | Adds kona-node + base-cl service definitions (+78 lines) |
| 14 | `devnet/2-deploy-op-contracts.sh` | WT (unstaged edits only) | CGT setup made non-fatal for bench |
| 15 | `devnet/config-op/intent.toml.bak` | WT (unstaged edits only) | Gas limit set to 500M |
| 16 | `devnet/dockerfile/Dockerfile.kona-node` | Committed | Kona docker build |
| 17 | `devnet/Dockerfile.base-consensus` | Committed | Base-cl docker build |
| 18 | `devnet/lib.sh` | Committed | Shared shell helpers |
| 19 | `devnet/config-op/l1-chain-config.json` | Committed | L1 chain config for kona |
| 20 | `devnet/.env` | WT (unstaged edits) | Repo path env vars (KONA_OKX_REPO, BASE_CL_REPO, etc.) |

**Copy method:** Files 13-15, 20 — copy manually (working-tree changes). Files 16-19 — `git checkout feature/kona-cl-hypothesis -- <path>`.

---

## Category 3 — Adventure (Go load generator)

Code changes to the adventure tool. **Must carry.**

| # | File | Source | Why carry |
|---|---|---|---|
| 21 | `tools/adventure/bench/erc20.go` | Committed (+24 lines) | Reth queued-promotion fix: committed nonce wait before next batch |
| 22 | `tools/adventure/utils/eth_client.go` | Committed (+20 lines) | New methods: `QueryCommittedNonce`, `SignTx` + Client interface |
| 23 | `tools/adventure/testdata/accounts-50k.txt` | Untracked | Master key file (50k pre-funded wallets) |
| 24 | `tools/adventure/testdata/accounts-25k-A.txt` | Untracked | Instance A keys (25k) |
| 25 | `tools/adventure/testdata/accounts-25k-B.txt` | Untracked | Instance B keys (25k) |

**Copy method:** Files 21-22 — `git checkout feature/kona-cl-hypothesis -- <path>`. Files 23-25 — copy manually (untracked).

> **Note:** `accounts-10k-A.txt`, `accounts-10k-B.txt`, `accounts-500-A.txt`, `accounts-500-B.txt` are also committed but superseded by the 25k/50k files. Carry them only if you want backward compatibility.

---

## Category 4 — Primary documentation

Main docs for the bench project. **Must carry.**

| # | File | Source | Why carry |
|---|---|---|---|
| 26 | `bench/README.md` | WT (committed + unstaged edits) | Bench project overview and file index |
| 27 | `bench/BENCH-GUIDE.md` | Untracked | Complete guide for running benchmarks |
| 28 | `bench/kona-cl-hypothesis.md` | WT (committed + unstaged edits) | Hypothesis document — kona vs op-node |
| 29 | `bench/load-guide.md` | WT (unstaged edits) | Load testing guide |
| 30 | `bench/report-read-guide.md` | WT (unstaged edits) | How to read bench reports |
| 31 | `bench/context-handoff.md` | Untracked | Context for session handoff |
| 32 | `bench/final-report-prompt.md` | Staged (new) | Prompt for final report generation |

**Copy method:** WT files — copy manually. Untracked/staged — copy manually or git checkout.

---

## Category 5 — Presentation (deliverable)

The final presentation document. **Must carry.**

| # | File | Source | Why carry |
|---|---|---|---|
| 33 | `bench/presentation/presentation.md` | Untracked | Main presentation document |
| 34 | `bench/presentation/cross-run-comparison.md` | Untracked | Cross-run data comparison |

**Copy method:** Copy files individually (not entire directory).

---

## Category 6 — Architecture documentation

kona architecture deep-dives. **Must carry.**

| # | File | Source | Why carry |
|---|---|---|---|
| 39 | `bench/kona/architecture/kona-architecture.md` | Staged (new, replaces old path) | Full kona architecture doc |
| 40 | `bench/kona/architecture/kona-fcu-deepdive.md` | Untracked | FCU deep dive |
| 41 | `bench/kona/architecture/terminology.md` | Untracked | Terminology reference (source of truth) |

**Copy method:** Copy entire `bench/kona/architecture/` directory.

---

## Category 7 — Optimisation documentation

Shipped optimisation docs. **Must carry.**

| # | File | Source | Why carry |
|---|---|---|---|
| 35 | `bench/kona/optimisations/README.md` | Untracked | Optimisations index |
| 36 | `bench/kona/optimisations/kona-optimisation-proposal.md` | Untracked | Optimisation proposal (covers both Opt-1 and Opt-2) |
| 37 | `bench/kona/optimisations/tps-impact-model.md` | Untracked | TPS impact model |
| 38 | `bench/kona/optimisations/L2-system-config-load-logic.md` | Untracked | SystemConfig load logic analysis |

**Copy method:** Copy these 4 files individually (not entire directory).

---

## Category 8 — CL comparison docs

Supporting analysis docs for each CL. **Carry selectively.**

| # | File | Source | Why carry |
|---|---|---|---|
| 39 | `bench/base/base-cl-deep-dive.md` | Untracked | base-cl analysis |
| 40 | `bench/base/base-cl-fcu-deepdive.md` | Untracked | base-cl FCU deep dive |
| 41 | `bench/base/base-cl-vs-kona-comparison.md` | Untracked | base-cl vs kona comparison |
| 42 | `bench/op-node/op-node-deep-dive.md` | Untracked | op-node analysis |
| 43 | `bench/op-node/op-node-vs-kona-comparison.md` | Untracked | op-node vs kona comparison |

**Copy method:** Copy files individually.

---

## SKIP — Do NOT carry

These files are deleted in working tree (superseded) or are generated/temporary:

### Superseded docs (deleted in working tree)
- `bench/BENCHMARKING.md` — replaced by BENCH-GUIDE.md
- `bench/ENGINE_PROBE_EXPLANATION.md` — old probe docs
- `bench/ENGINE_PROBE_FAQ.md`
- `bench/ENGINE_PROBE_SUMMARY.md`
- `bench/ENGINE_PROBE_VISUAL.md`
- `bench/FCU_LATENCY_BREAKDOWN.md`
- `bench/HOW-TO-RUN-LOAD-TEST.md` — replaced by load-guide.md
- `bench/LOAD_TEST_LATENCY_EXPLANATION.md`
- `bench/adventure-usage-guide.md` — superseded
- `bench/bench-adventure-internals.md` — superseded
- `bench/bench-adventure.sh` — moved to scripts/
- `bench/block-lifecycle.md` — superseded
- `bench/high-load-bench.sh` — superseded
- `bench/high-load-sender-erc20.py` — superseded
- `bench/high-load-sender.py` — superseded
- `bench/high-load-test-strategy.md` — superseded
- `bench/kona/findings.md` — superseded
- `bench/kona/kona-architecture.md` — moved to architecture/
- `bench/kona/kona-fcu-fix-deep-dive.md` — moved to misc/
- `bench/load-test.sh` — superseded
- `bench/simple-bench.sh` — superseded
- `bench/temp.md` — temporary

### Superseded reports (committed but content is stale)
- `bench/reports/CL-COMPARISON.md`
- `bench/reports/adventure-erc20-cl-comparison.md`
- `bench/reports/hypothesis.md`
- `bench/reports/kona-vs-opnode-xlayer-deepdive.md`
- `bench/reports/methodology.md`
- `bench/reports/op-node-vs-kona.md`
- `bench/reports/report.md`
- `bench/reports/results/` (templates)

### Old results (superseded by bench/runs/)
- `bench/base/results/` — all old raw results
- `bench/kona/results/` — all old raw results
- `bench/op-node/results/` — all old raw results
- `bench/base/base-consensus-architecture.md` — superseded

### Scratchpads and internal-only
- `bench/FCU_scratchpad.md` — working notes
- `bench/kona/misc/` — entire directory (internal analysis, superseded by optimisation docs)
- `bench/kona/optimisations/opt-1-fcu-binaryheap-drain.md` — covered by kona-optimisation-proposal.md
- `bench/kona/optimisations/opt-2-systemconfig-cache.md` — covered by kona-optimisation-proposal.md
- `bench/kona/optimisations/jira-tickets.md` — internal tracking

### Presentation assets (not needed)
- `bench/presentation/proposed-sections.md` — planning doc
- `bench/presentation/render-diagrams.sh` — build tool
- `bench/presentation/images/` — rendered PNGs (regenerate if needed)
- `bench/presentation/Technical document template.pdf` — reference template

### Scripts (not needed on new branch)
- `bench/build-bench-images.sh` — image builder (devnet-specific, not needed in clean branch)

### Temporary/backup
- `devnet/.env_backup.txt`
- `devnet/.env.kona-single-image.bak`
- `devnet/load-test-20260325_210631.txt`
- `devnet/load-test-20260325_214819.txt`

### Generated runs (separate concern)
- `bench/runs/*` — all run data (carry selectively if needed as evidence)

---

## Fastest copy approach

Since most files are untracked or have working-tree edits, the cleanest method is a **filesystem copy**:

```bash
# 1. Create new branch
git checkout main && git pull
git checkout -b feature/kona-cl-bench

# 2. Switch to old branch in a second terminal (or use a worktree)
cd /tmp && git clone --no-checkout ~/Documents/xlayer/xlayer-toolkit old-branch
cd old-branch && git checkout feature/kona-cl-hypothesis
# OR: use the working tree directly if not switching branches

# 3. Copy each category directory
SRC=~/Documents/xlayer/xlayer-toolkit  # old branch working tree
DST=.                                   # new branch (current dir)

# Scripts
cp "$SRC/bench/bench.sh" "$DST/bench/bench.sh"
cp "$SRC/bench/bench-orchestrate.sh" "$DST/bench/"
mkdir -p "$DST/bench/scripts"
cp "$SRC/bench/scripts/bench-adventure.sh" "$DST/bench/scripts/"
cp "$SRC/bench/scripts/generate-report.py" "$DST/bench/scripts/"
cp "$SRC/bench/scripts/generate-simple-report.py" "$DST/bench/scripts/"
cp "$SRC/bench/scripts/simple-report.template.md" "$DST/bench/scripts/"
cp "$SRC/bench/scripts/generate-phase-report.py" "$DST/bench/scripts/"
cp "$SRC/bench/scripts/compare-opt2.py" "$DST/bench/scripts/"
cp "$SRC/bench/scripts/fcu-tps-correlation.py" "$DST/bench/scripts/"
cp "$SRC/bench/scripts/patch-avg-stats.py" "$DST/bench/scripts/"
cp "$SRC/bench/scripts/repair-500m-stats.py" "$DST/bench/scripts/"

# Devnet
cp "$SRC/devnet/docker-compose.yml" "$DST/devnet/"
cp "$SRC/devnet/2-deploy-op-contracts.sh" "$DST/devnet/"
cp "$SRC/devnet/config-op/intent.toml.bak" "$DST/devnet/config-op/"
cp "$SRC/devnet/dockerfile/Dockerfile.kona-node" "$DST/devnet/dockerfile/"
cp "$SRC/devnet/Dockerfile.base-consensus" "$DST/devnet/"
cp "$SRC/devnet/lib.sh" "$DST/devnet/"
cp "$SRC/devnet/config-op/l1-chain-config.json" "$DST/devnet/config-op/"
cp "$SRC/devnet/.env" "$DST/devnet/.env"

# Adventure
cp "$SRC/tools/adventure/bench/erc20.go" "$DST/tools/adventure/bench/"
cp "$SRC/tools/adventure/utils/eth_client.go" "$DST/tools/adventure/utils/"
mkdir -p "$DST/tools/adventure/testdata"
cp "$SRC/tools/adventure/testdata/accounts-50k.txt" "$DST/tools/adventure/testdata/"
cp "$SRC/tools/adventure/testdata/accounts-25k-A.txt" "$DST/tools/adventure/testdata/"
cp "$SRC/tools/adventure/testdata/accounts-25k-B.txt" "$DST/tools/adventure/testdata/"

# Docs
cp "$SRC/bench/README.md" "$DST/bench/"
cp "$SRC/bench/BENCH-GUIDE.md" "$DST/bench/"
cp "$SRC/bench/kona-cl-hypothesis.md" "$DST/bench/"
cp "$SRC/bench/load-guide.md" "$DST/bench/"
cp "$SRC/bench/report-read-guide.md" "$DST/bench/"
cp "$SRC/bench/context-handoff.md" "$DST/bench/"
cp "$SRC/bench/final-report-prompt.md" "$DST/bench/"

# Presentation (selected files only)
mkdir -p "$DST/bench/presentation"
cp "$SRC/bench/presentation/presentation.md" "$DST/bench/presentation/"
cp "$SRC/bench/presentation/cross-run-comparison.md" "$DST/bench/presentation/"

# Architecture
mkdir -p "$DST/bench/kona/architecture"
cp -r "$SRC/bench/kona/architecture/" "$DST/bench/kona/architecture/"

# Optimisations (selected files only)
mkdir -p "$DST/bench/kona/optimisations"
cp "$SRC/bench/kona/optimisations/README.md" "$DST/bench/kona/optimisations/"
cp "$SRC/bench/kona/optimisations/kona-optimisation-proposal.md" "$DST/bench/kona/optimisations/"
cp "$SRC/bench/kona/optimisations/tps-impact-model.md" "$DST/bench/kona/optimisations/"
cp "$SRC/bench/kona/optimisations/L2-system-config-load-logic.md" "$DST/bench/kona/optimisations/"

# CL comparison docs
mkdir -p "$DST/bench/base" "$DST/bench/op-node"
cp "$SRC/bench/base/base-cl-deep-dive.md" "$DST/bench/base/"
cp "$SRC/bench/base/base-cl-fcu-deepdive.md" "$DST/bench/base/"
cp "$SRC/bench/base/base-cl-vs-kona-comparison.md" "$DST/bench/base/"
cp "$SRC/bench/op-node/op-node-deep-dive.md" "$DST/bench/op-node/"
cp "$SRC/bench/op-node/op-node-vs-kona-comparison.md" "$DST/bench/op-node/"

# 4. Stage and commit in logical groups
git add tools/adventure/ && git commit -m "feat(adventure): reth queued-promotion fix + 50k wallet keys"
git add devnet/ && git commit -m "feat(devnet): kona + base-cl docker configs and deploy scripts"
git add bench/bench.sh bench/bench-orchestrate.sh bench/scripts/ && git commit -m "feat(bench): orchestration scripts and report generators"
git add bench/presentation/ bench/kona/ bench/base/ bench/op-node/ && git commit -m "docs(bench): presentation, architecture, and analysis docs"
git add bench/ && git commit -m "docs(bench): guides, hypothesis, and comparison docs"
```

---

## Summary counts

| Category | Files | Must carry? |
|---|---|---|
| Scripts | 11 | Yes |
| Devnet config | 8 | Yes |
| Adventure code + keys | 5 | Yes |
| Primary docs | 7 | Yes |
| Presentation | 2 | Yes |
| Architecture docs | 3 | Yes |
| Optimisation docs | 4 | Yes |
| CL comparison docs | 5 | Selectively |
| **Total to carry** | **~45** | |
| Skip (superseded/temp/internal) | ~60 | No |
