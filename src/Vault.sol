// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Vault
/// @notice An open shared pool for the TTT token. Anyone can deposit; anyone can
///         withdraw up to the current pool balance into their own wallet. There is
///         no per-user accounting and no access control — by design. Security is
///         explicitly out of scope (see docs/superpowers/specs/2026-06-26-ttt-vault-design.md).
contract Vault {
    IERC20 public immutable token;

    event Deposit(address indexed from, uint256 amount);
    event Withdraw(address indexed to, uint256 amount);

    constructor(IERC20 token_) {
        token = token_;
    }

    /// @notice Pull `amount` of TTT from the caller into the pool. Caller must have
    ///         approved this contract for at least `amount` first.
    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, amount);
    }

    /// @notice Send `amount` of TTT from the pool to the caller. Reverts if `amount`
    ///         exceeds the current pool balance (the maximum).
    function withdraw(uint256 amount) external {
        require(amount <= token.balanceOf(address(this)), "amount exceeds pool balance");
        token.transfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }
}
