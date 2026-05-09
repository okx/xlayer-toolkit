.PHONY: help setup setup-light build test bench cross-check cross-fuzz bench-circom clean

help:
	@echo "poseidon2-opt — Makefile targets"
	@echo ""
	@echo "  make setup         populate lib/ AND download pot12.ptau (idempotent)"
	@echo "  make build         forge build (lib/ only — skips ptau)"
	@echo "  make test          forge test — correctness + fuzz suite (lib/ only)"
	@echo "  make bench         forge test — gas benchmark (lib/ only)"
	@echo "  make cross-check   Solidity <-> Circom equality on fixed inputs"
	@echo "  make cross-fuzz    Solidity <-> Circom equality on random inputs"
	@echo "                     (override count via CROSS_CHECK_FUZZ=N, default 4)"
	@echo "  make bench-circom  Circom R1CS + Groth16 proving benchmark"
	@echo "  make clean         remove Foundry and Circom build artifacts"

setup:
	@bash scripts/setup-libs.sh

# Solidity-only setup — lib/ clones without the ~5 MB pot12.ptau download.
setup-light:
	@SKIP_PTAU=1 bash scripts/setup-libs.sh

build: setup-light
	@forge build

test: setup-light
	@forge test

bench: setup-light
	@FOUNDRY_PROFILE=bench forge test -vv

cross-check: setup
	@bash test/cross_check.sh

cross-fuzz: setup
	@CROSS_CHECK_FUZZ=$${CROSS_CHECK_FUZZ:-4} bash test/cross_check.sh

bench-circom: setup
	@bash bench/circom/scripts/bench_full.sh

clean:
	@forge clean
	@rm -rf bench/circom/build_*
