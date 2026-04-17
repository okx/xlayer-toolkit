.PHONY: help setup build test bench cross-check bench-circom clean

help:
	@echo "poseidon2-opt — Makefile targets"
	@echo ""
	@echo "  make setup         populate lib/ and download pot12.ptau (idempotent)"
	@echo "  make build         forge build (runs setup first)"
	@echo "  make test          forge test — correctness suite"
	@echo "  make bench         forge test — gas benchmark (FOUNDRY_PROFILE=bench)"
	@echo "  make cross-check   Solidity <-> Circom output equality cross-check"
	@echo "  make bench-circom  Circom R1CS + Groth16 proving benchmark"
	@echo "  make clean         remove Foundry and Circom build artifacts"

setup:
	@bash scripts/setup-libs.sh

build: setup
	@forge build

test: setup
	@forge test

bench: setup
	@FOUNDRY_PROFILE=bench forge test -vv

cross-check:
	@bash test/cross_check.sh

bench-circom:
	@bash bench/circom/scripts/bench_full.sh

clean:
	@forge clean
	@rm -rf bench/circom/build_*
