// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice A minimal, freely-mintable ERC20 used as test collateral (a stand-in for USDC).
/// @dev FOR TESTING ONLY — `mint` is public with no access control, so anyone can create
///      tokens. Never deploy this to a real network. It inherits the full, audited ERC20
///      implementation (balances, transfer, approve, transferFrom) from OpenZeppelin.
contract MockERC20 is ERC20 {
    /// @param name_   human-readable token name, e.g. "Mock USDT"
    /// @param symbol_ ticker, e.g. "mUSDT"
    /// @dev The `ERC20(name_, symbol_)` part calls the parent constructor to set name/symbol.
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    /// @notice Create `amount` tokens out of thin air and give them to `to`.
    /// @dev `_mint` is the internal OZ function that increases `to`'s balance and totalSupply.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
