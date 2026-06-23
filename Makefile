# ──────────────────────────────────────────────────────────────────────────────
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
.PHONY: help build test test-v test-vvv all watch focus gas coverage fuzz invariant fmt fmt-check clean snapshot \
        deploy-prediction deploy-multioutcome deploy-factory verify wallet balance

## help: list all available targets
help:
	@echo "Available targets:"
	@grep -hE '^## ' $(MAKEFILE_LIST) | sed 's/## /  /'

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

# ──────────────────────────────────────────────────────────────────────────────
# Deployment — TEIZA devnet (chain 36854461)
# ──────────────────────────────────────────────────────────────────────────────
# One-time prereqs:
#   1. Keystore wallet:   cast wallet import teiza-dev --interactive
#   2. .env contains:     RPC_URL=https://rpc.teiza-devnet.gateway.fm
#   3. Fund the deployer (see `make wallet` / `make balance`) from the TEIZA faucet.
#
# Examples:
#   make deploy-multioutcome                       # reuse standard collateral, 2 slots
#   make deploy-multioutcome OUTCOME_SLOTS=3        # 3-way market (win/draw/loss)
#   make deploy-multioutcome COLLATERAL_ADDRESS=    # ALSO deploy a fresh mUSDT
#   make deploy-factory
#   make verify ADDRESS=0x.. CONTRACT=src/MarketFactory.sol:MarketFactory

# Pull RPC_URL (and anything else) from .env. `-include` => no error if absent.
-include .env

# Config — override on the command line, e.g. `make deploy-factory SENDER=0x...`.
ACCOUNT            ?= teiza-dev
SENDER             ?= 0x3445b7BE08b797dB06EBF0B95bB6B34bd137ef75
RPC_URL            ?= https://rpc.teiza-devnet.gateway.fm
EXPLORER_URL       ?= https://explorer.teiza-devnet.gateway.fm
VERIFIER           ?= blockscout
CHAIN_ID           ?= 36854461

# Standard shared collateral (the "one mUSDT" pattern). Set empty to deploy a fresh mock.
COLLATERAL_ADDRESS ?= 0x89e421920daF3D723Ab0B797B13b12D71e1CaF99
# MultiOutcomeMarket slots: 2 = binary/scalar, 3 = win/draw/loss, N = categorical.
OUTCOME_SLOTS      ?= 2

SCRIPT_FLAGS = --rpc-url $(RPC_URL) --account $(ACCOUNT) --sender $(SENDER) --broadcast
VERIFY_FLAGS = --verify --verifier $(VERIFIER) --verifier-url $(EXPLORER_URL)/api/
# Only put COLLATERAL_ADDRESS in the env when it is non-empty; an empty value cleanly
# falls back to each script's "deploy a fresh mock" branch (via vm.envOr).
COLLATERAL_ENV = $(if $(COLLATERAL_ADDRESS),COLLATERAL_ADDRESS=$(COLLATERAL_ADDRESS))

## deploy-prediction: deploy binary PredictionMarket (+ collateral), then verify
deploy-prediction:
	$(COLLATERAL_ENV) forge script script/DeployPredictionMarket.s.sol:DeployPredictionMarket $(SCRIPT_FLAGS) $(VERIFY_FLAGS)

## deploy-multioutcome: deploy MultiOutcomeMarket (OUTCOME_SLOTS, default 2), then verify
deploy-multioutcome:
	$(COLLATERAL_ENV) OUTCOME_SLOTS=$(OUTCOME_SLOTS) forge script script/DeployMultiOutcomeMarket.s.sol:DeployMultiOutcomeMarket $(SCRIPT_FLAGS) $(VERIFY_FLAGS)

## deploy-factory: deploy MarketFactory, then verify
deploy-factory:
	$(COLLATERAL_ENV) forge script script/DeployMarketFactory.s.sol:DeployMarketFactory $(SCRIPT_FLAGS) $(VERIFY_FLAGS)

## verify: re-verify a contract — make verify ADDRESS=0x.. CONTRACT=path:Name [CONSTRUCTOR_ARGS=0x..]
verify:
	forge verify-contract $(ADDRESS) $(CONTRACT) --verifier $(VERIFIER) --verifier-url $(EXPLORER_URL)/api/ $(if $(CONSTRUCTOR_ARGS),--constructor-args $(CONSTRUCTOR_ARGS)) --watch

## wallet: print the deployer address held in the keystore
wallet:
	cast wallet address --account $(ACCOUNT)

## balance: print the deployer's devnet gas balance
balance:
	cast balance $(SENDER) --rpc-url $(RPC_URL)
