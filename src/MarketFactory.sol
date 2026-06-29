// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PredictionMarket} from "./PredictionMarket.sol";

/// @title MarketFactory
/// @notice Deploys PredictionMarket instances and keeps an on-chain registry of them. A factory
///         gives you (1) one canonical address that front-ends/indexers watch for new markets,
///         (2) a trustworthy `s_isMarket` check so other contracts can verify an address really is
///         one of "our" markets, and (3) a single event stream of every market ever created.
/// @dev The factory is intentionally minimal and UN-privileged: it holds no funds, has no owner,
///      and cannot touch a market after creating it. Each market's own immutable `resolver`
///      (passed in by the caller) remains the sole authority over that market. All input
///      validation lives in the PredictionMarket constructor, so bad parameters revert there and
///      the registry is never polluted with a half-built market.
contract MarketFactory {
    /// @notice Every market this factory has deployed, in creation order.
    address[] public s_allMarkets;

    /// @notice True iff the address was deployed by THIS factory. Lets other contracts trust a
    ///         market's provenance without scanning `s_allMarkets`.
    mapping(address => bool) public s_isMarket;

    /// @notice Emitted once per deployment. `market`, `creator`, and `resolver` are indexed so
    ///         off-chain tools can filter by any of them.
    event MarketCreated(
        address indexed market,
        address indexed creator,
        address indexed resolver,
        address collateral,
        uint256 closeTime,
        uint16 feeBps,
        address feeVault
    );

    /// @notice Deploy a new PredictionMarket and register it.
    /// @param collateral ERC20 settlement token for the new market
    /// @param resolver   address allowed to resolve the new market (e.g. a multisig+timelock)
    /// @param closeTime  timestamp at which trading ends (must be in the future)
    /// @param feeBps     trading fee in basis points (must be < 100%)
    /// @param feeVault   external contract that receives all of the new market's trading fees
    /// @return market the freshly deployed PredictionMarket
    function createMarket(IERC20 collateral, address resolver, uint256 closeTime, uint16 feeBps, address feeVault)
        external
        returns (PredictionMarket market)
    {
        // `new` deploys a fresh PredictionMarket; its constructor validates every argument and
        // reverts on bad input, so we never reach the registry writes with a broken market.
        market = new PredictionMarket(collateral, resolver, closeTime, feeBps, feeVault);

        // ---- Effects: record the new market in the registry ----
        s_allMarkets.push(address(market));
        s_isMarket[address(market)] = true;

        emit MarketCreated(address(market), msg.sender, resolver, address(collateral), closeTime, feeBps, feeVault);
    }

    /// @notice Number of markets this factory has created (length of `s_allMarkets`).
    function marketsCount() external view returns (uint256) {
        return s_allMarkets.length;
    }
}
