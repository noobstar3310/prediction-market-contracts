le# ──────────────────────────────────────────────────────────────────────────────
# Makefile — repeatable commands for building, testing, and inspecting the
# contracts. Instead of remembering long `forge` invocations, run `make <target>`.
#
#   make            # same as `make test`
#   make help       # list every target with a description
#
# This is the single source of truth for "how do we run the tests" — CI and every
# developer use the exact same commands, so results are reproducible.
# ──────────────────────────────────────────────────────────────────────────────

# The market contract we're focused on. Override on the fly, e.g.
#   make test C=PredictionMarketTest
C ?= MultiOutcomeMarketTest

.DEFAULT_GOAL := test
.PHONY: help build test test-v test-vvv watch focus gas coverage fuzz invariant fmt fmt-check clean snapshot

## help: list all available targets
help:
	@echo "Available targets:"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  /'

## build: compile all contracts
build:
	forge build

## test: run the focused market test suite (override with C=OtherTest)
test:
	forge test --match-contract $(C)

## test-v: run the suite with logs (console2 narration)
test-v:
	forge test --match-contract $(C) -vv

## test-vvv: run the suite with full execution traces (for debugging a failure)
test-vvv:
	forge test --match-contract $(C) -vvv

## all: run the ENTIRE test suite across every contract
all:
	forge test

## focus: run a single test by name, e.g. make focus T=test_Scalar_FractionalPayout
focus:
	forge test --match-test $(T) -vvv

## watch: re-run the suite automatically on every file save
watch:
	forge test --match-contract $(C) --watch -vv

## gas: print a gas-usage report for the suite
gas:
	forge test --match-contract $(C) --gas-report

## snapshot: write a gas snapshot to .gas-snapshot (diff it to catch regressions)
snapshot:
	forge snapshot --match-contract $(C)

## coverage: show how much of the contract the tests exercise
coverage:
	forge coverage --match-contract $(C)

## fuzz: run only fuzz tests (random inputs), louder so you see the runs
fuzz:
	forge test --match-contract $(C) --match-test testFuzz -vv

## invariant: run only invariant tests (random call-sequences; proves solvency)
invariant:
	forge test --match-contract $(C) --match-test invariant -vv

## fmt: auto-format all Solidity files
fmt:
	forge fmt

## fmt-check: verify formatting without changing files (use this in CI)
fmt-check:
	forge fmt --check

## clean: delete build artifacts and cache
clean:
	forge clean
