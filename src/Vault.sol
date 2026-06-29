// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Vault
/// @notice An ERC20 payout vault. Anyone may fund it (open deposits), but ONLY the admin (owner)
///         may move funds out — paying a single user, or many users in one batch. The batch entry
///         point is the on-chain side of an admin UI where each "Add Transfer" row is one
///         (recipient, amount) pair submitted together.
/// @dev Custodies a single ERC20 (`i_token`) set at deployment, distributed with SafeERC20.
///      Payouts are all-or-nothing: a batch pre-checks its total against the vault balance and
///      reverts the entire call if it cannot pay everyone in full, so no one is partially paid.
contract Vault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The ERC20 token this vault holds and pays out. Set once, then immutable.
    IERC20 public immutable i_token;

    /// @notice Emitted when `from` funds the vault via deposit() with `amount` tokens.
    event Deposit(address indexed from, uint256 amount);
    /// @notice Emitted for each recipient paid (single payout or one leg of a batch).
    event Payout(address indexed to, uint256 amount);
    /// @notice Emitted once per batch: who ran it, how many recipients, and the total paid.
    event BatchDistributed(address indexed admin, uint256 recipients, uint256 totalAmount);

    /// @notice Constructor was given the zero address for the token.
    error Vault__ZeroToken();
    /// @notice A batch was submitted with no recipients.
    error Vault__EmptyBatch();
    /// @notice The recipients and amounts arrays have different lengths.
    error Vault__LengthMismatch();
    /// @notice A payout targeted the zero address.
    error Vault__ZeroRecipient();
    /// @notice A payout amount was zero where a positive value is required.
    error Vault__ZeroAmount();
    /// @notice The vault does not hold enough token to cover the requested payout.
    error Vault__InsufficientBalance(uint256 needed, uint256 available);
    /// @notice Renouncing ownership is disabled (it would freeze the vault's funds forever).
    error Vault__RenounceDisabled();

    /// @param token_ ERC20 token the vault holds and pays out (must be non-zero)
    /// @param admin_ initial owner/admin allowed to distribute funds (Ownable rejects address(0))
    constructor(IERC20 token_, address admin_) Ownable(admin_) {
        if (address(token_) == address(0)) revert Vault__ZeroToken();
        i_token = token_;
    }

    /// @notice Fund the vault by pulling `amount` of the token from the caller. Open to anyone.
    /// @dev Requires the caller to have approved this vault first. Funds may also arrive via a
    ///      plain ERC20 transfer straight to this address (e.g. a market routing fees here); such
    ///      transfers won't emit Deposit but are fully usable for payouts all the same.
    /// @param amount token amount to pull in
    function deposit(uint256 amount) external {
        if (amount == 0) revert Vault__ZeroAmount();
        i_token.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, amount);
    }

    /// @notice Admin-only: pay a single user `amount` of the token.
    /// @param to recipient wallet
    /// @param amount token amount to send
    function payout(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert Vault__ZeroRecipient();
        if (amount == 0) revert Vault__ZeroAmount();
        uint256 bal = i_token.balanceOf(address(this));
        if (amount > bal) revert Vault__InsufficientBalance(amount, bal);

        i_token.safeTransfer(to, amount);
        emit Payout(to, amount);
    }

    /// @notice Admin-only: pay many users in one transaction. `recipients[i]` receives `amounts[i]`.
    /// @dev The on-chain side of the admin table's "Add Transfer" rows — each row is one
    ///      (recipient, amount) pair. Atomic: the whole batch reverts if any entry is invalid or
    ///      the vault can't cover the total, so the table either fully succeeds or fully fails.
    ///      Keep batch sizes within the block gas limit (the admin controls how many rows to send).
    /// @param recipients user wallets to pay
    /// @param amounts token amount each recipient receives (parallel to `recipients`)
    function distribute(address[] calldata recipients, uint256[] calldata amounts)
        external
        onlyOwner
        nonReentrant
    {
        uint256 n = recipients.length;
        if (n == 0) revert Vault__EmptyBatch();
        if (n != amounts.length) revert Vault__LengthMismatch();

        // Validate every row and sum the batch BEFORE paying anyone, so the call is atomic and the
        // balance check is exact.
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            if (recipients[i] == address(0)) revert Vault__ZeroRecipient();
            if (amounts[i] == 0) revert Vault__ZeroAmount();
            total += amounts[i];
        }
        uint256 bal = i_token.balanceOf(address(this));
        if (total > bal) revert Vault__InsufficientBalance(total, bal);

        // Pay each recipient. The token is a trusted standard ERC20 (no transfer hooks to the
        // recipient), and the function is nonReentrant — so there is no reentrancy path here.
        for (uint256 i = 0; i < n; i++) {
            i_token.safeTransfer(recipients[i], amounts[i]);
            emit Payout(recipients[i], amounts[i]);
        }
        emit BatchDistributed(msg.sender, n, total);
    }

    /// @notice Current token balance available for payouts.
    function balance() external view returns (uint256) {
        return i_token.balanceOf(address(this));
    }

    /// @notice Disabled on purpose: an ownerless vault could never distribute its funds, freezing
    ///         them permanently. Hand off control with `transferOwnership` instead.
    function renounceOwnership() public view override onlyOwner {
        revert Vault__RenounceDisabled();
    }
}
