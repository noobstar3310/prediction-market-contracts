// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Vault
/// @notice An open shared pool for the chain's native token (ETH). Anyone can deposit;
///         anyone can withdraw up to the current pool balance into their own wallet.
///         There is no per-user accounting and no access control — by design.
contract Vault {
    event Deposit(address indexed from, uint256 amount);
    event Withdraw(address indexed to, uint256 amount);

    /// @notice Deposit native token into the pool. The value is sent with the call
    ///         itself (msg.value), so there is no approval step and no token argument.
    function deposit() external payable {
        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Send `amount` of native token from the pool to the caller.
    ///         Reverts if `amount` exceeds the current pool balance.
    function withdraw(uint256 amount) external {
        require(amount <= address(this).balance, "amount exceeds pool balance");
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "native transfer failed");
        emit Withdraw(msg.sender, amount);
    }
}
