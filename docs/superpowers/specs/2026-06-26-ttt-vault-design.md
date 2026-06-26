# TTT Vault — Design

**Date:** 2026-06-26
**Status:** Approved

## Purpose

An open shared pool for the TTT ERC20 token. Any user can deposit TTT; any user
can withdraw TTT to their own wallet, up to the current pool balance. Security is
explicitly out of scope — the goal is a working contract, not a safe one.

## Requirements

1. Any user can deposit TTT into the contract.
2. Any user can withdraw TTT from the contract into their own wallet.
3. Withdrawals may be any amount up to the maximum currently held (the pool balance).

## Out of Scope (deliberately cut)

- Per-user balance accounting — funds are commingled; anyone can withdraw what anyone deposited.
- SafeERC20, reentrancy guard, access control, pausing.
- Test suite.
- Token creation — TTT already exists on a devnet and is passed in at deploy time.

## Contract: `src/Vault.sol`

```solidity
constructor(IERC20 token)     // TTT address wired in at deploy
deposit(uint256 amount)       // token.transferFrom(msg.sender, this, amount)
withdraw(uint256 amount)      // require amount <= pool balance; token.transfer(msg.sender, amount)
```

- Holds an immutable `IERC20 token` reference set in the constructor.
- "Maximum" = `token.balanceOf(address(this))`. `withdraw` reverts with a clear
  error if `amount` exceeds it.
- Plain OpenZeppelin `IERC20` `transfer` / `transferFrom`. No SafeERC20, no guard.
- Events: `Deposit(address indexed from, uint256 amount)`, `Withdraw(address indexed to, uint256 amount)`.

## Deploy: `script/DeployVault.s.sol`

- Reads TTT address and deployer key from env (foundry `vm.envAddress` / standard `--private-key`).
- Broadcasts `new Vault(ttt)`.
- A `forge script` command is handed to the user; the user runs deployment.

## Dependencies

- OpenZeppelin `IERC20` (already remapped: `@openzeppelin/contracts/`).
- forge-std `Script` for the deploy script.
- TTT ERC20 deployed on devnet (address supplied at deploy time).
