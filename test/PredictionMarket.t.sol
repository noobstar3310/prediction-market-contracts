// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Stage 0 tests: the mock collateral works and the market constructor stores
///         configuration correctly and rejects invalid inputs.
contract PredictionMarketTest is Test {
    MockERC20 internal collateral;
    PredictionMarket internal market;

    // Named test actors. `makeAddr` derives a labelled address from a string (nice traces).
    address internal resolver = makeAddr("resolver");
    address internal alice = makeAddr("alice");

    uint256 internal closeTime;
    uint16 internal constant FEE_BPS = 200; // 2%

    // setUp() runs before EVERY test function, giving each test a fresh, isolated world.
    function setUp() public {
        collateral = new MockERC20("Mock USD", "mUSD");
        // closeTime must be in the future relative to the test's current block timestamp.
        closeTime = block.timestamp + 7 days;
        market = new PredictionMarket(collateral, resolver, closeTime, FEE_BPS);
    }

    // --- MockERC20 ---

    function test_Mock_MintAndTransfer() public {
        collateral.mint(alice, 1_000e18);
        assertEq(collateral.balanceOf(alice), 1_000e18, "mint should credit alice");

        vm.prank(alice); // make the next call's msg.sender == alice
        collateral.transfer(resolver, 400e18);

        assertEq(collateral.balanceOf(alice), 600e18, "alice balance after transfer");
        assertEq(collateral.balanceOf(resolver), 400e18, "resolver received transfer");
    }

    // --- Constructor stores config ---

    function test_Constructor_SetsImmutables() public view {
        assertEq(address(market.collateral()), address(collateral), "collateral set");
        assertEq(market.resolver(), resolver, "resolver set");
        assertEq(market.closeTime(), closeTime, "closeTime set");
        assertEq(market.feeBps(), FEE_BPS, "feeBps set");
        // Outcome enum's first member (Unset) is the default value 0 for a fresh market.
        assertEq(uint256(market.winningOutcome()), uint256(PredictionMarket.Outcome.Unset), "unresolved");
    }

    // --- Constructor input validation (each bad input must revert) ---

    function test_Constructor_RevertsOnZeroResolver() public {
        vm.expectRevert(PredictionMarket.ZeroResolver.selector);
        new PredictionMarket(collateral, address(0), closeTime, FEE_BPS);
    }

    function test_Constructor_RevertsOnPastCloseTime() public {
        vm.expectRevert(PredictionMarket.CloseTimeInPast.selector);
        new PredictionMarket(collateral, resolver, block.timestamp, FEE_BPS);
    }

    function test_Constructor_RevertsOnFeeTooHigh() public {
        vm.expectRevert(PredictionMarket.FeeTooHigh.selector);
        new PredictionMarket(collateral, resolver, closeTime, 10_000); // 100% not allowed
    }

    // ------------------------------------------------------------------------------
    // Stage 1: split / merge
    // ------------------------------------------------------------------------------

    /// @dev Helper: give `who` some collateral and pre-approve the market to pull it.
    function _fundAndApprove(address who, uint256 amount) internal {
        collateral.mint(who, amount);
        vm.prank(who);
        collateral.approve(address(market), amount);
    }

    function test_Split_MintsEqualSetsAndPullsCollateral() public {
        _fundAndApprove(alice, 100e18);

        vm.prank(alice);
        market.split(100e18);

        // Alice now holds a full set: equal YES and NO.
        assertEq(market.yesBalanceOf(alice), 100e18, "YES minted");
        assertEq(market.noBalanceOf(alice), 100e18, "NO minted");
        // Her collateral moved into the market contract.
        assertEq(collateral.balanceOf(alice), 0, "alice paid collateral");
        assertEq(collateral.balanceOf(address(market)), 100e18, "market holds collateral");
    }

    function test_Merge_ReversesSplitExactly() public {
        _fundAndApprove(alice, 100e18);

        vm.startPrank(alice); // startPrank: every call until stopPrank is from alice
        market.split(100e18);
        market.merge(100e18);
        vm.stopPrank();

        // Back to square one: no outcome tokens, full collateral returned.
        assertEq(market.yesBalanceOf(alice), 0, "YES burned");
        assertEq(market.noBalanceOf(alice), 0, "NO burned");
        assertEq(collateral.balanceOf(alice), 100e18, "collateral returned");
        assertEq(collateral.balanceOf(address(market)), 0, "market emptied");
    }

    function test_Merge_RevertsWhenSetIncomplete() public {
        _fundAndApprove(alice, 100e18);
        vm.startPrank(alice);
        market.split(100e18);
        // Spend one YES so the set is no longer complete (simulate by moving it away is
        // hard without transfer; instead try to merge MORE than owned).
        vm.expectRevert(PredictionMarket.InsufficientYes.selector);
        market.merge(150e18);
        vm.stopPrank();
    }

    function test_Split_RevertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.ZeroAmount.selector);
        market.split(0);
    }

    /// @notice Seed of the solvency invariant: the market's collateral balance always
    ///         equals the total number of complete sets outstanding (here, alice's).
    function test_Split_SolvencySeed() public {
        _fundAndApprove(alice, 100e18);
        vm.prank(alice);
        market.split(100e18);

        // Every YES is paired with a NO (a full set), and each set is backed by 1 collateral.
        uint256 outstandingSets = market.yesBalanceOf(alice); // == noBalanceOf(alice)
        assertEq(collateral.balanceOf(address(market)), outstandingSets, "fully backed");
    }
}
