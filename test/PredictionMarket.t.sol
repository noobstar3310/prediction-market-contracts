// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Tests for PredictionMarket, with verbose contextual logging.
/// @dev Run `forge test -vv` to read the narration in your terminal. The console2.log lines
///      describe each step and dump state so you can "watch" the contract behave.
contract PredictionMarketTest is Test {
    MockERC20 internal collateral;
    PredictionMarket internal market;

    // Named test actors. `makeAddr` derives a labelled address from a string (nice traces).
    address internal resolver = makeAddr("resolver");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal closeTime;
    uint16 internal constant FEE_BPS = 200; // 2%

    PredictionMarket internal mkt; // fee-free market used for the Stage 2 math tests

    // setUp() runs before EVERY test function, giving each test a fresh, isolated world.
    function setUp() public {
        console2.log("");
        console2.log("################## setUp ##################");
        collateral = new MockERC20("Mock USD", "mUSD");
        console2.log("Deployed MockERC20 collateral at:", address(collateral));

        // closeTime must be in the future relative to the test's current block timestamp.
        closeTime = block.timestamp + 7 days;
        console2.log("block.timestamp now :", block.timestamp);
        console2.log("market closeTime    :", closeTime);

        market = new PredictionMarket(collateral, resolver, closeTime, FEE_BPS);
        console2.log("Deployed PredictionMarket at:", address(market));
        console2.log("  resolver:", resolver);
        console2.log("  feeBps  :", FEE_BPS);
        console2.log("###########################################");
    }

    // ==============================================================================
    // Logging helpers (read these to understand the dumps below)
    // ==============================================================================

    /// @dev Print the pool's core state. Prices only exist once the pool is funded.
    function _logMarket(string memory label, PredictionMarket m) internal view {
        console2.log(string.concat("-- pool state: ", label, " --"));
        console2.log("   reserveYes :", m.reserveYes());
        console2.log("   reserveNo  :", m.reserveNo());
        console2.log("   totalShares:", m.totalShares());
        if (m.totalShares() > 0) {
            console2.log("   priceYes(/1e18):", m.priceYes());
            console2.log("   priceNo (/1e18):", m.priceNo());
        } else {
            console2.log("   (pool not funded yet - no price)");
        }
    }

    /// @dev Print one actor's full position in market `m`.
    function _logActor(string memory name, address who, PredictionMarket m) internal view {
        console2.log(string.concat("   [", name, "]"));
        console2.log("     collateral:", collateral.balanceOf(who));
        console2.log("     YES       :", m.yesBalanceOf(who));
        console2.log("     NO        :", m.noBalanceOf(who));
        console2.log("     LP shares :", m.sharesOf(who));
    }

    function _banner(string memory name) internal pure {
        console2.log("");
        console2.log(string.concat("==================== ", name, " ===================="));
    }

    // ==============================================================================
    // MockERC20
    // ==============================================================================

    function test_Mock_MintAndTransfer() public {
        _banner("test_Mock_MintAndTransfer");
        console2.log("Minting 1,000e18 mUSD to alice...");
        collateral.mint(alice, 1_000e18);
        console2.log("  alice balance:", collateral.balanceOf(alice));
        assertEq(collateral.balanceOf(alice), 1_000e18, "mint should credit alice");

        console2.log("alice transfers 400e18 to resolver...");
        vm.prank(alice); // make the next call's msg.sender == alice
        collateral.transfer(resolver, 400e18);

        console2.log("  alice    :", collateral.balanceOf(alice));
        console2.log("  resolver :", collateral.balanceOf(resolver));
        assertEq(collateral.balanceOf(alice), 600e18, "alice balance after transfer");
        assertEq(collateral.balanceOf(resolver), 400e18, "resolver received transfer");
    }

    // ==============================================================================
    // Constructor
    // ==============================================================================

    function test_Constructor_SetsImmutables() public view {
        console2.log("");
        console2.log("==================== test_Constructor_SetsImmutables ====================");
        console2.log("Reading immutables back from the deployed market:");
        console2.log("  collateral:", address(market.collateral()));
        console2.log("  resolver  :", market.resolver());
        console2.log("  closeTime :", market.closeTime());
        console2.log("  feeBps    :", market.feeBps());
        console2.log("  winningOutcome (0=Unset):", uint256(market.winningOutcome()));
        assertEq(address(market.collateral()), address(collateral), "collateral set");
        assertEq(market.resolver(), resolver, "resolver set");
        assertEq(market.closeTime(), closeTime, "closeTime set");
        assertEq(market.feeBps(), FEE_BPS, "feeBps set");
        // Outcome enum's first member (Unset) is the default value 0 for a fresh market.
        assertEq(uint256(market.winningOutcome()), uint256(PredictionMarket.Outcome.Unset), "unresolved");
    }

    function test_Constructor_RevertsOnZeroResolver() public {
        _banner("test_Constructor_RevertsOnZeroResolver");
        console2.log("Deploying with resolver = address(0) -> expect revert ZeroResolver");
        vm.expectRevert(PredictionMarket.PredictionMarket__ZeroResolver.selector);
        new PredictionMarket(collateral, address(0), closeTime, FEE_BPS);
    }

    function test_Constructor_RevertsOnPastCloseTime() public {
        _banner("test_Constructor_RevertsOnPastCloseTime");
        console2.log("Deploying with closeTime = now -> expect revert CloseTimeInPast");
        vm.expectRevert(PredictionMarket.PredictionMarket__CloseTimeInPast.selector);
        new PredictionMarket(collateral, resolver, block.timestamp, FEE_BPS);
    }

    function test_Constructor_RevertsOnFeeTooHigh() public {
        _banner("test_Constructor_RevertsOnFeeTooHigh");
        console2.log("Deploying with feeBps = 10000 (100%) -> expect revert FeeTooHigh");
        vm.expectRevert(PredictionMarket.PredictionMarket__FeeTooHigh.selector);
        new PredictionMarket(collateral, resolver, closeTime, 10_000); // 100% not allowed
    }

    // ==============================================================================
    // Stage 1: split / merge
    // ==============================================================================

    /// @dev Helper: give `who` some collateral and pre-approve the market to pull it.
    function _fundAndApprove(address who, uint256 amount) internal {
        collateral.mint(who, amount);
        vm.prank(who);
        collateral.approve(address(market), amount);
        console2.log("Funded actor with collateral and approved market spend:", amount);
    }

    function test_Split_MintsEqualSetsAndPullsCollateral() public {
        _banner("test_Split_MintsEqualSetsAndPullsCollateral");
        _fundAndApprove(alice, 100e18);
        _logActor("alice before", alice, market);

        console2.log("alice splits 100e18 collateral -> 100e18 YES + 100e18 NO");
        vm.prank(alice);
        market.split(100e18);

        _logActor("alice after", alice, market);
        console2.log("market collateral balance:", collateral.balanceOf(address(market)));

        // Alice now holds a full set: equal YES and NO.
        assertEq(market.yesBalanceOf(alice), 100e18, "YES minted");
        assertEq(market.noBalanceOf(alice), 100e18, "NO minted");
        // Her collateral moved into the market contract.
        assertEq(collateral.balanceOf(alice), 0, "alice paid collateral");
        assertEq(collateral.balanceOf(address(market)), 100e18, "market holds collateral");
    }

    function test_Merge_ReversesSplitExactly() public {
        _banner("test_Merge_ReversesSplitExactly");
        _fundAndApprove(alice, 100e18);

        console2.log("alice splits then immediately merges 100e18...");
        vm.startPrank(alice); // startPrank: every call until stopPrank is from alice
        market.split(100e18);
        _logActor("alice after split", alice, market);
        market.merge(100e18);
        vm.stopPrank();
        _logActor("alice after merge", alice, market);

        // Back to square one: no outcome tokens, full collateral returned.
        assertEq(market.yesBalanceOf(alice), 0, "YES burned");
        assertEq(market.noBalanceOf(alice), 0, "NO burned");
        assertEq(collateral.balanceOf(alice), 100e18, "collateral returned");
        assertEq(collateral.balanceOf(address(market)), 0, "market emptied");
    }

    function test_Merge_RevertsWhenSetIncomplete() public {
        _banner("test_Merge_RevertsWhenSetIncomplete");
        _fundAndApprove(alice, 100e18);
        vm.startPrank(alice);
        market.split(100e18);
        console2.log("alice holds 100e18 of each; trying to merge 150e18 -> expect InsufficientYes");
        // Try to merge MORE than owned.
        vm.expectRevert(PredictionMarket.PredictionMarket__InsufficientYes.selector);
        market.merge(150e18);
        vm.stopPrank();
    }

    function test_Split_RevertsOnZero() public {
        _banner("test_Split_RevertsOnZero");
        console2.log("alice splits 0 -> expect revert ZeroAmount");
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.PredictionMarket__ZeroAmount.selector);
        market.split(0);
    }

    /// @notice Seed of the solvency invariant: the market's collateral balance always
    ///         equals the total number of complete sets outstanding (here, alice's).
    function test_Split_SolvencySeed() public {
        _banner("test_Split_SolvencySeed");
        _fundAndApprove(alice, 100e18);
        vm.prank(alice);
        market.split(100e18);

        // Every YES is paired with a NO (a full set), and each set is backed by 1 collateral.
        uint256 outstandingSets = market.yesBalanceOf(alice); // == noBalanceOf(alice)
        console2.log("outstanding complete sets:", outstandingSets);
        console2.log("market collateral held   :", collateral.balanceOf(address(market)));
        console2.log("=> held == sets  (solvent)");
        assertEq(collateral.balanceOf(address(market)), outstandingSets, "fully backed");
    }

    // ==============================================================================
    // Stage 2: funding, pricing, buy/sell
    // We use a FEE-FREE market here so the math is exact and hand-verifiable.
    // (Fees get their own tests in Stage 3.)
    // ==============================================================================

    /// @dev Deploy a 0-fee market and give alice & bob a big collateral allowance.
    function _setUpNoFeeMarket() internal {
        mkt = new PredictionMarket(collateral, resolver, closeTime, 0);
        console2.log("Deployed FEE-FREE market at:", address(mkt));
        collateral.mint(alice, 1_000_000);
        collateral.mint(bob, 1_000_000);
        vm.prank(alice);
        collateral.approve(address(mkt), type(uint256).max);
        vm.prank(bob);
        collateral.approve(address(mkt), type(uint256).max);
        console2.log("Minted 1,000,000 to alice & bob; both approved the market.");
    }

    function test_AddLiquidity_FirstFundingIs5050() public {
        _banner("test_AddLiquidity_FirstFundingIs5050");
        _setUpNoFeeMarket();
        _logMarket("before funding", mkt);

        console2.log("alice adds 1000 liquidity (first funding)...");
        vm.prank(alice);
        mkt.addLiquidity(1000);
        _logMarket("after funding", mkt);
        _logActor("alice", alice, mkt);

        assertEq(mkt.reserveYes(), 1000, "rY seeded");
        assertEq(mkt.reserveNo(), 1000, "rN seeded");
        assertEq(mkt.totalShares(), 1000, "shares minted");
        assertEq(mkt.sharesOf(alice), 1000, "alice owns all shares");
        // Equal reserves => 0.50 each (0.5 * 1e18 = 5e17), and they sum to WAD.
        assertEq(mkt.priceYes(), 5e17, "priceYes = 0.50");
        assertEq(mkt.priceNo(), 5e17, "priceNo = 0.50");
        assertEq(mkt.priceYes() + mkt.priceNo(), mkt.WAD(), "prices sum to 1");
    }

    function test_AddLiquidity_RevertsOnSecondFunding() public {
        _banner("test_AddLiquidity_RevertsOnSecondFunding");
        _setUpNoFeeMarket();
        vm.startPrank(alice);
        mkt.addLiquidity(1000);
        console2.log("Funding a second time in Stage 2 -> expect AlreadyFunded (Stage 4 lifts this)");
        vm.expectRevert(PredictionMarket.PredictionMarket__AlreadyFunded.selector);
        mkt.addLiquidity(1000);
        vm.stopPrank();
    }

    function test_Price_RevertsBeforeFunding() public {
        _banner("test_Price_RevertsBeforeFunding");
        _setUpNoFeeMarket();
        console2.log("Reading priceYes() on an unfunded pool -> expect PoolNotFunded");
        vm.expectRevert(PredictionMarket.PredictionMarket__PoolNotFunded.selector);
        mkt.priceYes();
    }

    /// @notice The fully hand-computed buy example from our lesson:
    ///         fund 1000/1000, buy YES with 1000 -> 1500 shares, reserves 500/2000, price 0.80.
    function test_Buy_HandComputedExample() public {
        _banner("test_Buy_HandComputedExample");
        _setUpNoFeeMarket();
        vm.prank(alice);
        mkt.addLiquidity(1000); // rY = rN = 1000, k = 1_000_000
        _logMarket("after funding 1000/1000", mkt);

        console2.log("Quoting buy of YES with 1000 collateral...");
        uint256 quoted = mkt.calcBuyAmount(PredictionMarket.Outcome.Yes, 1000);
        console2.log("  calcBuyAmount =>", quoted, "(hand math: 2000 - ceil(1e6/2000) = 1500)");
        assertEq(quoted, 1500, "calcBuyAmount matches hand math");

        console2.log("bob buys YES with 1000 collateral, minOut=1500...");
        vm.prank(bob);
        mkt.buy(PredictionMarket.Outcome.Yes, 1000, 1500);
        _logMarket("after bob's YES buy", mkt);
        _logActor("bob", bob, mkt);

        assertEq(mkt.yesBalanceOf(bob), 1500, "bob got 1500 YES");
        assertEq(mkt.reserveYes(), 500, "rY' = 500");
        assertEq(mkt.reserveNo(), 2000, "rN' = 2000");
        // Buying YES pushed YES price up to 0.80 and NO down to 0.20.
        assertEq(mkt.priceYes(), 8e17, "priceYes = 0.80");
        assertEq(mkt.priceNo(), 2e17, "priceNo = 0.20");
        // k is preserved (here exactly): 500 * 2000 == 1000 * 1000.
        console2.log("k before:", uint256(1000 * 1000), " k after:", mkt.reserveYes() * mkt.reserveNo());
        assertEq(mkt.reserveYes() * mkt.reserveNo(), 1000 * 1000, "k preserved");
    }

    function test_Buy_RevertsOnSlippage() public {
        _banner("test_Buy_RevertsOnSlippage");
        _setUpNoFeeMarket();
        vm.prank(alice);
        mkt.addLiquidity(1000);

        console2.log("Quote is 1500 out; bob demands minOut=1501 -> expect SlippageExceeded");
        vm.prank(bob);
        vm.expectRevert(PredictionMarket.PredictionMarket__SlippageExceeded.selector);
        mkt.buy(PredictionMarket.Outcome.Yes, 1000, 1501);
    }

    /// @notice Round-trip: with 0 fee and exact division, selling back to recover the full
    ///         investment costs exactly the shares you received (no free profit).
    function test_BuyThenSell_NoProfitAtZeroFee() public {
        _banner("test_BuyThenSell_NoProfitAtZeroFee");
        _setUpNoFeeMarket();
        vm.prank(alice);
        mkt.addLiquidity(1000);

        console2.log("bob buys YES with 1000 (gets 1500)...");
        vm.prank(bob);
        uint256 got = 1500;
        mkt.buy(PredictionMarket.Outcome.Yes, 1000, got);
        _logMarket("after buy", mkt);

        console2.log("Now bob wants his 1000 back. How many YES must he return?");
        uint256 sharesIn = mkt.calcSellAmount(PredictionMarket.Outcome.Yes, 1000);
        console2.log("  calcSellAmount(YES,1000) =>", sharesIn, "(he received 1500)");
        assertGe(sharesIn, got, "cannot round-trip into a profit");
        assertEq(sharesIn, 1500, "exact here: 1000 + ceil(500*2000/1000) - 500 = 1500");

        vm.prank(bob);
        mkt.sell(PredictionMarket.Outcome.Yes, 1000, sharesIn);
        console2.log("bob collateral after full round-trip:", collateral.balanceOf(bob));
        assertEq(collateral.balanceOf(bob), 1_000_000, "bob fully recovered, no gain");
    }

    function test_Sell_RevertsOnSlippage() public {
        _banner("test_Sell_RevertsOnSlippage");
        _setUpNoFeeMarket();
        vm.prank(alice);
        mkt.addLiquidity(1000);
        vm.prank(bob);
        mkt.buy(PredictionMarket.Outcome.Yes, 1000, 1500);

        console2.log("sharesIn would be 1500; bob caps maxIn=1499 -> expect SlippageExceeded");
        vm.prank(bob);
        vm.expectRevert(PredictionMarket.PredictionMarket__SlippageExceeded.selector);
        mkt.sell(PredictionMarket.Outcome.Yes, 1000, 1499);
    }

    function test_Sell_RevertsWhenReturnTooHigh() public {
        _banner("test_Sell_RevertsWhenReturnTooHigh");
        _setUpNoFeeMarket();
        vm.prank(alice);
        mkt.addLiquidity(1000);
        console2.log("Asking to pull out 1000 when opposite reserve is only 1000 -> ReturnTooHigh");
        vm.expectRevert(PredictionMarket.PredictionMarket__ReturnTooHigh.selector);
        mkt.calcSellAmount(PredictionMarket.Outcome.Yes, 1000); // rOther = 1000, R = 1000 >= rOther
    }

    function test_Buy_RevertsOnInvalidOutcome() public {
        _banner("test_Buy_RevertsOnInvalidOutcome");
        _setUpNoFeeMarket();
        vm.prank(alice);
        mkt.addLiquidity(1000);
        console2.log("bob buys Outcome.Unset (0) -> expect InvalidOutcome");
        vm.prank(bob);
        vm.expectRevert(PredictionMarket.PredictionMarket__InvalidOutcome.selector);
        mkt.buy(PredictionMarket.Outcome.Unset, 1000, 0);
    }

    function test_Buy_RevertsAfterClose() public {
        _banner("test_Buy_RevertsAfterClose");
        _setUpNoFeeMarket();
        vm.prank(alice);
        mkt.addLiquidity(1000);
        console2.log("Warping to closeTime:", closeTime);
        vm.warp(closeTime);
        console2.log("bob tries to buy after close -> expect TradingClosed");
        vm.prank(bob);
        vm.expectRevert(PredictionMarket.PredictionMarket__TradingClosed.selector);
        mkt.buy(PredictionMarket.Outcome.Yes, 1000, 0);
    }

    /// @notice Solvency holds after a trade: collateral held >= both total outcome supplies.
    function test_Buy_KeepsSolvent() public {
        _banner("test_Buy_KeepsSolvent");
        _setUpNoFeeMarket();
        vm.prank(alice);
        mkt.addLiquidity(1000);
        vm.prank(bob);
        mkt.buy(PredictionMarket.Outcome.Yes, 1000, 1500);

        uint256 totalYes = mkt.reserveYes() + mkt.yesBalanceOf(bob);
        uint256 totalNo = mkt.reserveNo() + mkt.noBalanceOf(bob);
        uint256 held = collateral.balanceOf(address(mkt));
        console2.log("total YES in existence:", totalYes);
        console2.log("total NO  in existence:", totalNo);
        console2.log("collateral held by mkt:", held);
        console2.log("=> held >= each total (solvent)");
        assertGe(held, totalYes, "collateral backs all YES");
        assertGe(held, totalNo, "collateral backs all NO");
    }
}
