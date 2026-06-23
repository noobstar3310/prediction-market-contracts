// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {MultiOutcomeMarket} from "../src/MultiOutcomeMarket.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Tests for the generalized N-outcome market, with verbose contextual logging.
/// @dev Run `forge test --match-contract MultiOutcomeMarketTest -vv` to read the narration.
///      The three poll types differ ONLY by `outcomeSlotCount` + the payout vector passed to
///      `resolve` — these tests prove exactly that:
///        - BINARY      : 2 slots, resolve([0,1])
///        - CATEGORICAL : N slots, resolve([0,1,0]) (winner) or [1,1,1] (void/refund)
///        - SCALAR      : 2 slots, resolve([hi-v, v-lo]) (fractional "where in range")
contract MultiOutcomeMarketTest is Test {
    MockERC20 internal collateral;

    address internal resolver = makeAddr("resolver");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal closeTime;
    uint16 internal constant FEE_BPS = 200; // 2%
    uint256 internal constant WAD = 1e18;

    function setUp() public {
        collateral = new MockERC20("Mock USDT", "mUSDT");
        closeTime = block.timestamp + 7 days;
    }

    // ==============================================================================
    // Helpers
    // ==============================================================================

    /// @dev Deploy a market with `n` outcome slots and the shared test config.
    function _deploy(uint256 n) internal returns (MultiOutcomeMarket m) {
        m = new MultiOutcomeMarket(collateral, resolver, closeTime, FEE_BPS, n);
    }

    /// @dev Give `who` collateral and pre-approve the market to pull it.
    function _fund(MultiOutcomeMarket m, address who, uint256 amount) internal {
        collateral.mint(who, amount);
        vm.prank(who);
        collateral.approve(address(m), type(uint256).max);
    }

    /// @dev Independently recompute a holder's expected redemption from the payout vector.
    ///      Mirrors redeem()'s formula so we validate the on-chain math against a clean reimpl.
    function _expectedRedeem(MultiOutcomeMarket m, address who) internal view returns (uint256 exp) {
        uint256 n = m.outcomeSlotCount();
        uint256 den = m.payoutDenominator();
        for (uint256 i = 0; i < n; i++) {
            exp += m.balanceOf(i, who) * m.payoutNumerators(i) / den;
        }
    }

    function _logReserves(MultiOutcomeMarket m) internal view {
        uint256[] memory r = m.getReserves();
        for (uint256 i = 0; i < r.length; i++) {
            console2.log("   reserve[", i, "]:", r[i]);
        }
        console2.log("   totalShares:", m.totalShares());
    }

    function _banner(string memory name) internal pure {
        console2.log("");
        console2.log(string.concat("==================== ", name, " ===================="));
    }

    // ==============================================================================
    // Constructor
    // ==============================================================================

    function test_Constructor_SetsConfigAndSizesReserves() public {
        _banner("test_Constructor_SetsConfigAndSizesReserves");
        MultiOutcomeMarket m = _deploy(3);
        assertEq(address(m.collateral()), address(collateral), "collateral set");
        assertEq(m.resolver(), resolver, "resolver set");
        assertEq(m.outcomeSlotCount(), 3, "slot count set");
        assertEq(m.getReserves().length, 3, "reserves pre-sized to N");
        assertEq(m.payoutDenominator(), 0, "starts unresolved");
    }

    function test_Constructor_RejectsBadOutcomeCount() public {
        _banner("test_Constructor_RejectsBadOutcomeCount");
        // < 2 outcomes is meaningless for a market.
        vm.expectRevert(MultiOutcomeMarket.MultiOutcomeMarket__BadOutcomeCount.selector);
        _deploy(1);
        // > MAX_OUTCOMES is rejected.
        vm.expectRevert(MultiOutcomeMarket.MultiOutcomeMarket__BadOutcomeCount.selector);
        _deploy(257);
    }

    // ==============================================================================
    // Split / merge (N outcomes)
    // ==============================================================================

    function test_SplitThenMerge_RoundTrips() public {
        _banner("test_SplitThenMerge_RoundTrips");
        MultiOutcomeMarket m = _deploy(3);
        _fund(m, alice, 100e18);

        vm.prank(alice);
        m.split(100e18);
        console2.log("After split, alice holds one unit of each outcome:");
        for (uint256 i = 0; i < 3; i++) {
            assertEq(m.balanceOf(i, alice), 100e18, "split credits each outcome");
        }
        assertEq(collateral.balanceOf(address(m)), 100e18, "collateral locked 1:1");

        vm.prank(alice);
        m.merge(100e18);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(m.balanceOf(i, alice), 0, "merge burns each outcome");
        }
        assertEq(collateral.balanceOf(alice), 100e18, "alice fully refunded by merge");
    }

    // ==============================================================================
    // Liquidity + pricing
    // ==============================================================================

    function test_AddLiquidity_SeedsUniformPoolAndPricesSumToOne() public {
        _banner("test_AddLiquidity_SeedsUniformPoolAndPricesSumToOne");
        MultiOutcomeMarket m = _deploy(3);
        _fund(m, carol, 300e18);

        vm.prank(carol);
        m.addLiquidity(300e18);
        _logReserves(m);

        // First funding seeds every reserve equal → every price == 1/N, summing to WAD.
        uint256 sum;
        for (uint256 i = 0; i < 3; i++) {
            assertEq(m.getReserves()[i], 300e18, "uniform seed");
            uint256 p = m.marginalPrice(i);
            console2.log("   price[", i, "]:", p);
            sum += p;
        }
        // Allow 1 wei rounding dust across N divisions.
        assertApproxEqAbs(sum, WAD, 2, "prices sum to ~1");
    }

    function test_Buy_MovesPriceTowardBoughtOutcome() public {
        _banner("test_Buy_MovesPriceTowardBoughtOutcome");
        MultiOutcomeMarket m = _deploy(3);
        _fund(m, carol, 300e18);
        vm.prank(carol);
        m.addLiquidity(300e18);

        uint256 priceBefore = m.marginalPrice(1);
        _fund(m, alice, 100e18);
        uint256 quoted = m.calcBuyAmount(1, 100e18);
        console2.log("quoted shares of outcome 1 for 100e18:", quoted);

        vm.prank(alice);
        m.buy(1, 100e18, quoted); // minSharesOut == quote (no slippage in a static test)
        assertEq(m.balanceOf(1, alice), quoted, "buyer credited the quoted amount");

        uint256 priceAfter = m.marginalPrice(1);
        console2.log("price[1] before:", priceBefore);
        console2.log("price[1] after :", priceAfter);
        assertGt(priceAfter, priceBefore, "buying outcome 1 makes it more expensive");
    }

    // ==============================================================================
    // Resolution access control
    // ==============================================================================

    function test_Resolve_Guards() public {
        _banner("test_Resolve_Guards");
        MultiOutcomeMarket m = _deploy(2);
        uint256[] memory payout = new uint256[](2);
        payout[0] = 0;
        payout[1] = 1;

        // Not the resolver.
        vm.warp(closeTime);
        vm.expectRevert(MultiOutcomeMarket.MultiOutcomeMarket__NotResolver.selector);
        m.resolve(payout);

        // Resolver, but before closeTime.
        vm.warp(closeTime - 1);
        vm.prank(resolver);
        vm.expectRevert(MultiOutcomeMarket.MultiOutcomeMarket__NotClosed.selector);
        m.resolve(payout);

        // Wrong vector length.
        vm.warp(closeTime);
        uint256[] memory bad = new uint256[](3);
        bad[2] = 1;
        vm.prank(resolver);
        vm.expectRevert(MultiOutcomeMarket.MultiOutcomeMarket__BadPayoutVector.selector);
        m.resolve(bad);

        // Valid, then second resolve is rejected.
        vm.prank(resolver);
        m.resolve(payout);
        assertEq(m.payoutDenominator(), 1, "resolved");
        vm.prank(resolver);
        vm.expectRevert(MultiOutcomeMarket.MultiOutcomeMarket__AlreadyResolved.selector);
        m.resolve(payout);
    }

    // ==============================================================================
    // CATEGORICAL — one-hot winner: resolve([0,1,0])
    // ==============================================================================

    function test_Categorical_OneHot_WinnerRedeemsLoserGetsNothing() public {
        _banner("test_Categorical_OneHot_WinnerRedeemsLoserGetsNothing");
        MultiOutcomeMarket m = _deploy(3);

        // Seed a pool so there's something to trade against.
        _fund(m, carol, 300e18);
        vm.prank(carol);
        m.addLiquidity(300e18);

        // alice bets on outcome 1 (the eventual winner); bob bets on outcome 0 (a loser).
        _fund(m, alice, 100e18);
        vm.prank(alice);
        m.buy(1, 100e18, 0);
        _fund(m, bob, 100e18);
        vm.prank(bob);
        m.buy(0, 100e18, 0);

        // Resolve: outcome 1 (B) wins.
        vm.warp(closeTime);
        uint256[] memory payout = new uint256[](3);
        payout[1] = 1; // [0,1,0]
        vm.prank(resolver);
        m.resolve(payout);

        // alice (winner) redeems her outcome-1 balance 1:1.
        uint256 aliceShares = m.balanceOf(1, alice);
        uint256 expAlice = _expectedRedeem(m, alice);
        assertEq(expAlice, aliceShares, "winner payout == winning balance");

        uint256 before = collateral.balanceOf(alice);
        vm.prank(alice);
        m.redeem();
        assertEq(collateral.balanceOf(alice) - before, expAlice, "alice paid exactly her winnings");
        console2.log("alice redeemed:", expAlice);

        // bob holds ONLY outcome 0 (a loser) → payout 0 → redeem reverts.
        vm.prank(bob);
        vm.expectRevert(MultiOutcomeMarket.MultiOutcomeMarket__NothingToRedeem.selector);
        m.redeem();
    }

    // ==============================================================================
    // CATEGORICAL — void / refund: resolve([1,1,1])
    // ==============================================================================

    function test_Categorical_VoidRefund_FullSetReturnsStake() public {
        _banner("test_Categorical_VoidRefund_FullSetReturnsStake");
        MultiOutcomeMarket m = _deploy(3);
        _fund(m, alice, 90e18);

        // alice splits → holds 90 of each outcome (a full set, stake = 90).
        vm.prank(alice);
        m.split(90e18);

        // Market voided: every outcome pays equally → each token worth 1/3, full set worth 1.
        vm.warp(closeTime);
        uint256[] memory payout = new uint256[](3);
        payout[0] = 1;
        payout[1] = 1;
        payout[2] = 1; // [1,1,1]
        vm.prank(resolver);
        m.resolve(payout);

        uint256 exp = _expectedRedeem(m, alice);
        console2.log("expected refund:", exp);
        vm.prank(alice);
        m.redeem();
        assertEq(collateral.balanceOf(alice), 90e18, "void refunds full stake");
    }

    // ==============================================================================
    // SCALAR — fractional "where in range": resolve([hi-v, v-lo])
    // ==============================================================================

    function test_Scalar_FractionalPayout() public {
        _banner("test_Scalar_FractionalPayout");
        // Range $50k–$100k, final value $80k. LOW=index0, HIGH=index1.
        // payout = [hi - v, v - lo] = [100k-80k, 80k-50k] = [20000, 30000], denom 50000.
        // → LOW redeems at 40%, HIGH at 60%.
        MultiOutcomeMarket m = _deploy(2);
        _fund(m, alice, 100e18);

        vm.prank(alice);
        m.split(100e18); // 100 LOW + 100 HIGH

        vm.warp(closeTime);
        uint256[] memory payout = new uint256[](2);
        payout[0] = 20000; // LOW
        payout[1] = 30000; // HIGH
        vm.prank(resolver);
        m.resolve(payout);

        // A full-set holder still gets their whole stake back (fractions sum to 1).
        uint256 exp = _expectedRedeem(m, alice);
        assertEq(exp, 100e18, "full set redeems to stake regardless of split");

        // And the fractions are exactly 40% / 60% on each leg.
        assertEq(m.balanceOf(0, alice) * 20000 / 50000, 40e18, "LOW leg worth 40%");
        assertEq(m.balanceOf(1, alice) * 30000 / 50000, 60e18, "HIGH leg worth 60%");

        vm.prank(alice);
        m.redeem();
        assertEq(collateral.balanceOf(alice), 100e18, "scalar full-set refund exact");
    }

    // ==============================================================================
    // Solvency — a mixed scenario must never leave the pool unable to pay
    // ==============================================================================

    function test_Solvency_MixedScenario() public {
        _banner("test_Solvency_MixedScenario");
        MultiOutcomeMarket m = _deploy(3);

        _fund(m, carol, 300e18); // LP
        vm.prank(carol);
        m.addLiquidity(300e18);

        _fund(m, alice, 100e18);
        vm.prank(alice);
        m.buy(1, 100e18, 0);

        _fund(m, bob, 50e18);
        vm.prank(bob);
        m.buy(0, 50e18, 0);

        uint256 held = collateral.balanceOf(address(m));
        console2.log("collateral held by market:", held);

        vm.warp(closeTime);
        uint256[] memory payout = new uint256[](3);
        payout[1] = 1; // outcome 1 wins
        vm.prank(resolver);
        m.resolve(payout);

        // Everyone who can redeem, does. carol exits LP first (turns reserves into tokens + fees).
        // NB: read sharesOf into a local BEFORE prank — a view call between prank and the target
        // call would consume the prank (Foundry only applies it to the very next call).
        uint256 carolShares = m.sharesOf(carol);
        vm.prank(carol);
        m.removeLiquidity(carolShares);
        if (m.balanceOf(1, carol) > 0) {
            vm.prank(carol);
            m.redeem();
        }
        vm.prank(alice);
        m.redeem();

        // The contract paid every claimant without reverting → it stayed solvent. Any residual is
        // the unredeemable losing-side backing + dust, which can only be >= 0.
        console2.log("collateral remaining in market:", collateral.balanceOf(address(m)));
        assertLe(
            collateral.balanceOf(alice) + collateral.balanceOf(carol),
            held + 100e18 + 50e18,
            "no value created from nothing"
        );
    }
}
