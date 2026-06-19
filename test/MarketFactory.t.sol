// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Tests for MarketFactory: it deploys wired-up markets, registers them, emits an event,
///         and propagates the market's own constructor validation.
contract MarketFactoryTest is Test {
    MarketFactory internal factory;
    MockERC20 internal collateral;

    address internal resolver = makeAddr("resolver");
    address internal creator = makeAddr("creator");
    uint256 internal closeTime;
    uint16 internal constant FEE_BPS = 200;

    function setUp() public {
        factory = new MarketFactory();
        collateral = new MockERC20("Mock USD", "mUSD");
        closeTime = block.timestamp + 7 days;
    }

    /// @notice A created market is fully wired with the params we passed, and the factory holds
    ///         no special power over it (the resolver is whoever we named).
    function test_CreateMarket_DeploysWiredMarket() public {
        console2.log("creator calls factory.createMarket(...)");
        vm.prank(creator);
        PredictionMarket market = factory.createMarket(collateral, resolver, closeTime, FEE_BPS);
        console2.log("  new market:", address(market));

        assertEq(address(market.collateral()), address(collateral), "collateral wired");
        assertEq(market.resolver(), resolver, "resolver wired (not the factory)");
        assertEq(market.closeTime(), closeTime, "closeTime wired");
        assertEq(market.feeBps(), FEE_BPS, "feeBps wired");
        // Sanity: the factory is NOT the resolver — it has no authority over the market.
        assertTrue(market.resolver() != address(factory), "factory holds no power over the market");
    }

    /// @notice The market is recorded in the registry: isMarket flips true and it lands in
    ///         allMarkets / marketsCount.
    function test_CreateMarket_RegistersMarket() public {
        assertEq(factory.marketsCount(), 0, "registry starts empty");

        vm.prank(creator);
        PredictionMarket market = factory.createMarket(collateral, resolver, closeTime, FEE_BPS);

        assertEq(factory.marketsCount(), 1, "count incremented");
        assertEq(factory.allMarkets(0), address(market), "stored at index 0");
        assertTrue(factory.isMarket(address(market)), "isMarket true for our market");
        assertFalse(factory.isMarket(address(0xdead)), "isMarket false for a random address");
    }

    /// @notice createMarket emits MarketCreated with the right data and indexed topics.
    function test_CreateMarket_EmitsEvent() public {
        // We don't know the market address in advance, so don't check topic1 (the market addr);
        // we DO check creator (topic2), resolver (topic3), and the data fields.
        vm.expectEmit(false, true, true, true, address(factory));
        emit MarketFactory.MarketCreated(
            address(0), creator, resolver, address(collateral), closeTime, FEE_BPS
        );
        vm.prank(creator);
        factory.createMarket(collateral, resolver, closeTime, FEE_BPS);
    }

    /// @notice Two markets get distinct addresses and both register, in order.
    function test_CreateMarket_TwoMarketsAreDistinct() public {
        vm.startPrank(creator);
        PredictionMarket m1 = factory.createMarket(collateral, resolver, closeTime, FEE_BPS);
        PredictionMarket m2 = factory.createMarket(collateral, resolver, closeTime + 1 days, 0);
        vm.stopPrank();

        assertTrue(address(m1) != address(m2), "distinct deployments");
        assertEq(factory.marketsCount(), 2, "both counted");
        assertEq(factory.allMarkets(0), address(m1), "m1 at index 0");
        assertEq(factory.allMarkets(1), address(m2), "m2 at index 1");
    }

    /// @notice The market constructor's validation is enforced through the factory: a bad param
    ///         reverts the whole createMarket and never pollutes the registry.
    function test_CreateMarket_PropagatesConstructorValidation() public {
        console2.log("createMarket with closeTime in the past -> expect CloseTimeInPast");
        vm.expectRevert(PredictionMarket.PredictionMarket__CloseTimeInPast.selector);
        factory.createMarket(collateral, resolver, block.timestamp, FEE_BPS);
        assertEq(factory.marketsCount(), 0, "registry untouched on failed creation");
    }
}
