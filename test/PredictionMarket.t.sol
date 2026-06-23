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
    address internal carol = makeAddr("carol");

    uint256 internal closeTime;
    uint16 internal constant FEE_BPS = 200; // 2%

    PredictionMarket internal mkt; // fee-free market used for the Stage 2 math tests

    // setUp() runs before EVERY test function, giving each test a fresh, isolated world.
    function setUp() public {
        console2.log("");
        console2.log("################## setUp ##################");
        collateral = new MockERC20("Mock USDT", "mUSDT");
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

    /// @notice Stage 4: a second LP funding an UNBALANCED pool preserves the price, mints
    ///         proportional shares, and gets the surplus of the pricier side back.
    function test_AddLiquidity_SecondFundingPreservesPrice() public {
        _banner("test_AddLiquidity_SecondFundingPreservesPrice");
        _setUpNoFeeMarket();
        vm.prank(alice);
        mkt.addLiquidity(1000); // 1000/1000
        vm.prank(bob);
        mkt.buy(PredictionMarket.Outcome.Yes, 1000, 1500); // -> reserves 500/2000, price 0.80
        _logMarket("before carol funds (unbalanced)", mkt);

        uint256 priceBefore = mkt.priceYes();

        // carol adds 1000 to the unbalanced pool.
        collateral.mint(carol, 1000);
        vm.prank(carol);
        collateral.approve(address(mkt), type(uint256).max);
        vm.prank(carol);
        mkt.addLiquidity(1000);
        _logMarket("after carol funds", mkt);
        _logActor("carol", carol, mkt);

        // poolWeight = max(500,2000) = 2000.
        // shares = 1000*1000/2000 = 500; keepYes = 1000*500/2000 = 250; keepNo = 1000.
        // surplus YES to carol = 1000 - 250 = 750; reserves -> 750/3000.
        assertEq(mkt.priceYes(), priceBefore, "price preserved across funding");
        assertEq(mkt.priceYes(), 8e17, "still 0.80");
        assertEq(mkt.sharesOf(carol), 500, "carol minted proportional shares");
        assertEq(mkt.yesBalanceOf(carol), 750, "carol got surplus YES");
        assertEq(mkt.noBalanceOf(carol), 0, "no NO surplus (NO was the larger reserve)");
        assertEq(mkt.reserveYes(), 750, "rY grew proportionally");
        assertEq(mkt.reserveNo(), 3000, "rN grew proportionally");
        assertEq(mkt.totalShares(), 1500, "total shares 1000 + 500");
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

    // ==============================================================================
    // Stage 3: fees
    // The fee MATH was built in Stage 2; here we prove the 2% fee (`market`, feeBps=200)
    // is actually retained as collateral and makes round-tripping lossy. LPs CLAIMING
    // those fees arrives with removeLiquidity in Stage 4.
    // ==============================================================================

    /// @dev Give `who` collateral and a max approval on the fee-charging `market`.
    function _seedFeeMarket(address who) internal {
        collateral.mint(who, 1_000_000);
        vm.prank(who);
        collateral.approve(address(market), type(uint256).max);
    }

    /// @notice After a buy on a 2% market, exactly the fee stays behind as bare collateral.
    function test_Fee_BuyRetainsTwoPercent() public {
        _banner("test_Fee_BuyRetainsTwoPercent");
        _seedFeeMarket(alice);
        _seedFeeMarket(bob);

        vm.prank(alice);
        market.addLiquidity(1000); // rY = rN = 1000
        console2.log("alice funded fee-market 1000/1000");

        // x = 1000 * (10000-200)/10000 = 980 enters the curve; 20 is the fee.
        vm.prank(bob);
        market.buy(PredictionMarket.Outcome.Yes, 1000, 0);
        _logMarket("after bob buys YES w/ 1000 (fee 2%)", market);
        _logActor("bob", bob, market);

        uint256 held = collateral.balanceOf(address(market));
        uint256 totalYes = market.reserveYes() + market.yesBalanceOf(bob);
        uint256 totalNo = market.reserveNo() + market.noBalanceOf(bob);
        console2.log("collateral held :", held);
        console2.log("total YES       :", totalYes);
        console2.log("total NO        :", totalNo);
        console2.log("fee buffer (held - totalNO):", held - totalNo);

        // The fee buffer = collateral that is NOT backing any outcome token = the 2% fee.
        assertEq(held - totalNo, 20, "fee buffer == 2% of 1000");
        assertEq(held - totalYes, 20, "fee buffer the same vs YES side");
    }

    /// @notice A fee buyer receives fewer shares than they would on a fee-free market.
    function test_Fee_GivesFewerSharesThanZeroFee() public {
        _banner("test_Fee_GivesFewerSharesThanZeroFee");
        // Fee market funded 1000/1000:
        _seedFeeMarket(alice);
        vm.prank(alice);
        market.addLiquidity(1000);

        // Fee-free market funded identically:
        _setUpNoFeeMarket();
        vm.prank(alice);
        mkt.addLiquidity(1000);

        uint256 qFee = market.calcBuyAmount(PredictionMarket.Outcome.Yes, 1000);
        uint256 qFree = mkt.calcBuyAmount(PredictionMarket.Outcome.Yes, 1000);
        console2.log("shares for 1000 @2% fee  :", qFee);
        console2.log("shares for 1000 @0% fee  :", qFree);
        assertEq(qFree, 1500, "0% fee: 1500 (from Stage 2)");
        assertEq(qFee, 1474, "2% fee: fewer shares");
        assertLt(qFee, qFree, "fee buyer always gets fewer shares");
    }

    /// @notice With a fee, you cannot round-trip your money back: reclaiming the full
    ///         investment would cost MORE shares than the buy ever gave you.
    function test_Fee_RoundTripIsLossy() public {
        _banner("test_Fee_RoundTripIsLossy");
        _seedFeeMarket(alice);
        _seedFeeMarket(bob);
        vm.prank(alice);
        market.addLiquidity(1000);

        vm.prank(bob);
        market.buy(PredictionMarket.Outcome.Yes, 1000, 0);
        uint256 received = market.yesBalanceOf(bob);
        console2.log("bob received YES:", received);

        // How many YES would bob need to return to get his full 1000 back?
        uint256 needed = market.calcSellAmount(PredictionMarket.Outcome.Yes, 1000);
        console2.log("YES needed to reclaim 1000:", needed);
        console2.log("=> needed > received, so the fee makes it lossy");
        assertGt(needed, received, "fee makes a full round-trip impossible");
    }

    /// @notice The fee buffer keeps the market strictly OVER-collateralized (extra safety).
    function test_Fee_LeavesPositiveBuffer() public {
        _banner("test_Fee_LeavesPositiveBuffer");
        _seedFeeMarket(alice);
        _seedFeeMarket(bob);
        vm.prank(alice);
        market.addLiquidity(1000);
        vm.prank(bob);
        market.buy(PredictionMarket.Outcome.Yes, 1000, 0);

        uint256 held = collateral.balanceOf(address(market));
        uint256 totalYes = market.reserveYes() + market.yesBalanceOf(bob);
        console2.log("held:", held, " totalYES:", totalYes);
        assertGt(held, totalYes, "fee buffer makes held strictly > obligations");
    }

    // ==============================================================================
    // Stage 4: multi-LP add / remove liquidity
    // ==============================================================================

    /// @notice Sole LP, no trades: removing all shares returns the full deposit as collateral.
    function test_RemoveLiquidity_SoloFullExit() public {
        _banner("test_RemoveLiquidity_SoloFullExit");
        _setUpNoFeeMarket();
        vm.startPrank(alice);
        mkt.addLiquidity(1000); // alice now down 1000 collateral
        _logActor("alice after fund", alice, mkt);
        mkt.removeLiquidity(1000); // burn all shares
        vm.stopPrank();
        _logActor("alice after exit", alice, mkt);
        _logMarket("pool after exit", mkt);

        // Balanced pool, no trades -> all reserves merge back to collateral, no residual.
        assertEq(collateral.balanceOf(alice), 1_000_000, "alice fully recovered her deposit");
        assertEq(mkt.reserveYes(), 0, "reserves drained");
        assertEq(mkt.reserveNo(), 0, "reserves drained");
        assertEq(mkt.totalShares(), 0, "all shares burned");
        assertEq(mkt.yesBalanceOf(alice), 0, "no residual YES");
        assertEq(mkt.noBalanceOf(alice), 0, "no residual NO");
    }

    /// @notice After trades, the sole LP exits with collateral + their fees + a residual
    ///         (one-sided) outcome position — illustrating LP directional risk.
    function test_RemoveLiquidity_RecoversFeesAndResidual() public {
        _banner("test_RemoveLiquidity_RecoversFeesAndResidual");
        _seedFeeMarket(alice);
        _seedFeeMarket(bob);
        vm.prank(alice);
        market.addLiquidity(1000); // alice: 1,000,000 -> 999,000
        vm.prank(bob);
        market.buy(PredictionMarket.Outcome.Yes, 1000, 0); // reserves 506/1980, collectedFees 20

        assertEq(market.collectedFees(), 20, "2% fee accrued");
        _logMarket("before alice exits", market);

        vm.prank(alice);
        market.removeLiquidity(1000); // sole LP burns all shares
        _logActor("alice after exit", alice, market);

        // sendYes=506, sendNo=1980, feeShare=20, mergeable=506 -> collateralOut=506+20=526,
        // residual NO = 1980-506 = 1474.
        assertEq(collateral.balanceOf(alice), 999_000 + 526, "collateral = merged sets + fees");
        assertEq(market.noBalanceOf(alice), 1474, "residual NO position (directional risk)");
        assertEq(market.yesBalanceOf(alice), 0, "no residual YES");
        assertEq(market.collectedFees(), 0, "all fees withdrawn by the LP");
        assertEq(market.reserveYes(), 0, "reserves drained");
        assertEq(market.reserveNo(), 0, "reserves drained");

        // Solvency: contract still backs bob's 1474 YES and alice's 1474 NO exactly.
        uint256 held = collateral.balanceOf(address(market));
        console2.log("held after exit:", held, " (backs bob's 1474 YES / alice's 1474 NO)");
        assertEq(held, 1474, "contract holds exactly the outstanding backing");
    }

    /// @notice Two equal LPs split accrued fees proportionally (50/50 here).
    function test_RemoveLiquidity_TwoLPsSplitFeesProportionally() public {
        _banner("test_RemoveLiquidity_TwoLPsSplitFeesProportionally");
        _seedFeeMarket(alice);
        _seedFeeMarket(bob);
        _seedFeeMarket(carol);

        vm.prank(alice);
        market.addLiquidity(1000); // alice 100% of 1000 shares
        vm.prank(bob);
        market.addLiquidity(1000); // balanced 50/50 -> bob mints 1000 shares; total 2000

        // carol trades, generating fees.
        vm.prank(carol);
        market.buy(PredictionMarket.Outcome.Yes, 1000, 0);
        uint256 fees = market.collectedFees();
        console2.log("fees accrued from carol's trade:", fees);
        assertEq(fees, 20, "2% of 1000");

        // alice owns 1000/2000 = 50% -> should withdraw half the fees.
        vm.prank(alice);
        market.removeLiquidity(1000);
        console2.log("collectedFees after alice exits:", market.collectedFees());
        assertEq(market.collectedFees(), 10, "alice took half the fees");

        // bob now owns 1000/1000 = 100% of the remaining pool -> takes the rest.
        vm.prank(bob);
        market.removeLiquidity(1000);
        console2.log("collectedFees after bob exits:", market.collectedFees());
        assertEq(market.collectedFees(), 0, "bob took the other half");
    }

    function test_RemoveLiquidity_RevertsOnTooManyShares() public {
        _banner("test_RemoveLiquidity_RevertsOnTooManyShares");
        _setUpNoFeeMarket();
        vm.startPrank(alice);
        mkt.addLiquidity(1000);
        console2.log("alice has 1000 shares; removing 1001 -> expect InsufficientShares");
        vm.expectRevert(PredictionMarket.PredictionMarket__InsufficientShares.selector);
        mkt.removeLiquidity(1001);
        vm.stopPrank();
    }

    // ==============================================================================
    // Stage 5: resolution + redemption
    // The resolver declares the winner after closeTime; winners burn their winning
    // tokens for collateral 1:1; losers' tokens are worthless. We test the access /
    // timing / idempotency guards on resolve(), the 1:1 payout on redeem(), and that
    // the whole market drains with no insolvency.
    // ==============================================================================

    // ------- resolve(): guards -------

    function test_Resolve_RevertsForNonResolver() public {
        _banner("test_Resolve_RevertsForNonResolver");
        _setUpNoFeeMarket();
        vm.prank(alice);
        mkt.addLiquidity(1000);
        vm.warp(closeTime); // market is now closed
        console2.log("alice (not the resolver) tries to resolve -> expect NotResolver");
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.PredictionMarket__NotResolver.selector);
        mkt.resolve(PredictionMarket.Outcome.Yes);
    }

    function test_Resolve_RevertsBeforeClose() public {
        _banner("test_Resolve_RevertsBeforeClose");
        _setUpNoFeeMarket();
        vm.prank(alice);
        mkt.addLiquidity(1000);
        console2.log("resolver resolves BEFORE closeTime -> expect NotClosed");
        console2.log("  block.timestamp:", block.timestamp, " closeTime:", closeTime);
        vm.prank(resolver);
        vm.expectRevert(PredictionMarket.PredictionMarket__NotClosed.selector);
        mkt.resolve(PredictionMarket.Outcome.Yes);
    }

    function test_Resolve_RevertsOnUnset() public {
        _banner("test_Resolve_RevertsOnUnset");
        _setUpNoFeeMarket();
        vm.prank(alice);
        mkt.addLiquidity(1000);
        vm.warp(closeTime);
        console2.log("resolver resolves with Outcome.Unset (the sentinel) -> expect InvalidOutcome");
        vm.prank(resolver);
        vm.expectRevert(PredictionMarket.PredictionMarket__InvalidOutcome.selector);
        mkt.resolve(PredictionMarket.Outcome.Unset);
    }

    function test_Resolve_RevertsOnSecondResolve() public {
        _banner("test_Resolve_RevertsOnSecondResolve");
        _setUpNoFeeMarket();
        vm.prank(alice);
        mkt.addLiquidity(1000);
        vm.warp(closeTime);
        console2.log("resolver resolves YES once...");
        vm.prank(resolver);
        mkt.resolve(PredictionMarket.Outcome.Yes);
        console2.log("...then tries to flip it to NO -> expect AlreadyResolved");
        vm.prank(resolver);
        vm.expectRevert(PredictionMarket.PredictionMarket__AlreadyResolved.selector);
        mkt.resolve(PredictionMarket.Outcome.No);
    }

    /// @notice Happy path: resolving exactly AT closeTime works (boundary), sets the winner,
    ///         and emits Resolved.
    function test_Resolve_SetsWinnerAndEmits() public {
        _banner("test_Resolve_SetsWinnerAndEmits");
        _setUpNoFeeMarket();
        vm.prank(alice);
        mkt.addLiquidity(1000);

        vm.warp(closeTime); // resolve is allowed at >= closeTime; test the exact boundary
        console2.log("Warped to exactly closeTime; resolver resolves YES.");

        // Expect the Resolved(Yes) event (no indexed fields, so we check the data).
        vm.expectEmit(true, true, true, true, address(mkt));
        emit PredictionMarket.Resolved(PredictionMarket.Outcome.Yes);

        vm.prank(resolver);
        mkt.resolve(PredictionMarket.Outcome.Yes);

        console2.log("winningOutcome (1=Yes):", uint256(mkt.winningOutcome()));
        assertEq(uint256(mkt.winningOutcome()), uint256(PredictionMarket.Outcome.Yes), "winner recorded");
    }

    // ------- redeem(): payouts -------

    function test_Redeem_RevertsBeforeResolved() public {
        _banner("test_Redeem_RevertsBeforeResolved");
        _setUpNoFeeMarket();
        vm.prank(alice);
        mkt.split(100); // alice holds 100 YES + 100 NO
        console2.log("alice redeems before any resolution -> expect NotResolved");
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.PredictionMarket__NotResolved.selector);
        mkt.redeem();
    }

    /// @notice A winner burns winning tokens for collateral 1:1; the leftover (losing) balance
    ///         is worthless and a second redeem finds nothing.
    function test_Redeem_WinnerPaid1to1() public {
        _banner("test_Redeem_WinnerPaid1to1");
        _setUpNoFeeMarket();

        console2.log("alice splits 100 -> 100 YES + 100 NO (collateral 100 locked in market)");
        vm.prank(alice);
        mkt.split(100);
        assertEq(collateral.balanceOf(alice), 1_000_000 - 100, "alice paid 100 to split");
        _logActor("alice after split", alice, mkt);

        vm.warp(closeTime);
        vm.prank(resolver);
        mkt.resolve(PredictionMarket.Outcome.Yes); // YES wins

        console2.log("alice redeems her 100 winning YES for 100 collateral...");
        vm.prank(alice);
        mkt.redeem();
        _logActor("alice after redeem", alice, mkt);

        assertEq(collateral.balanceOf(alice), 1_000_000, "alice made whole 1:1 on her YES");
        assertEq(mkt.yesBalanceOf(alice), 0, "winning balance zeroed");
        assertEq(mkt.noBalanceOf(alice), 100, "losing NO left untouched (worth 0)");

        console2.log("alice redeems again -> nothing left -> expect NothingToRedeem");
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.PredictionMarket__NothingToRedeem.selector);
        mkt.redeem();
    }

    /// @notice A holder of only the LOSING outcome can redeem nothing.
    function test_Redeem_LoserGetsNothing() public {
        _banner("test_Redeem_LoserGetsNothing");
        _setUpNoFeeMarket();
        vm.prank(alice);
        mkt.addLiquidity(1000);
        console2.log("bob buys NO with 1000 (so bob holds ONLY NO tokens)...");
        vm.prank(bob);
        mkt.buy(PredictionMarket.Outcome.No, 1000, 0);
        _logActor("bob", bob, mkt);

        vm.warp(closeTime);
        vm.prank(resolver);
        mkt.resolve(PredictionMarket.Outcome.Yes); // YES wins -> bob's NO is worthless

        console2.log("bob (holds only the losing NO) redeems -> expect NothingToRedeem");
        vm.prank(bob);
        vm.expectRevert(PredictionMarket.PredictionMarket__NothingToRedeem.selector);
        mkt.redeem();
        assertEq(collateral.balanceOf(bob), 1_000_000 - 1000, "loser recovers nothing");
    }

    // ------- end-to-end solvency -------

    /// @notice Full lifecycle on a fee-free market with a single LP, proving the market drains
    ///         to exactly zero with every winner paid in full (no insolvency), and that it is a
    ///         zero-sum transfer between the winning trader and the losing LP.
    function test_FullDrain_NoInsolvency() public {
        _banner("test_FullDrain_NoInsolvency");
        _setUpNoFeeMarket();

        // alice is the LP; bob bets YES.
        vm.prank(alice);
        mkt.addLiquidity(1000); // rY=rN=1000, alice: 1,000,000 -> 999,000
        vm.prank(bob);
        mkt.buy(PredictionMarket.Outcome.Yes, 1000, 1500); // reserves 500/2000, bob: 999,000, 1500 YES
        _logMarket("after bob's YES buy", mkt);

        // Invariant snapshot: totalYES == totalNO == 2000, collateral held == 2000.
        assertEq(collateral.balanceOf(address(mkt)), 2000, "held backs the 2000 sets");

        vm.warp(closeTime);
        vm.prank(resolver);
        mkt.resolve(PredictionMarket.Outcome.Yes); // YES wins

        // --- Post-resolution solvency invariant: held >= reserve(winner) + sum winning balances ---
        uint256 held = collateral.balanceOf(address(mkt));
        uint256 winningClaims = mkt.reserveYes() + mkt.yesBalanceOf(bob); // alice has 0 YES yet
        console2.log("held:", held, " reserve(YES)+winningBalances:", winningClaims);
        assertGe(held, winningClaims, "solvent: collateral covers every winning claim");

        // --- Drain: LP exits first (allowed post-resolution — no whenOpen gate), then redeems ---
        vm.prank(alice);
        mkt.removeLiquidity(1000); // sole LP: merges 500 sets -> 500 collateral, keeps 1500 residual NO
        _logActor("alice after LP exit", alice, mkt);
        assertEq(collateral.balanceOf(alice), 999_000 + 500, "alice got 500 from merged sets");
        assertEq(mkt.noBalanceOf(alice), 1500, "alice holds 1500 NO (the losing side)");
        assertEq(mkt.yesBalanceOf(alice), 0, "alice has no winning YES");

        // alice holds only losing NO -> redeem reverts (nothing to claim).
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.PredictionMarket__NothingToRedeem.selector);
        mkt.redeem();

        // bob redeems his 1500 winning YES for 1500 collateral.
        vm.prank(bob);
        mkt.redeem();
        _logActor("bob after redeem", bob, mkt);

        // --- Final accounting ---
        assertEq(collateral.balanceOf(address(mkt)), 0, "market fully drained, no dust, no insolvency");
        assertEq(collateral.balanceOf(bob), 1_000_000 + 500, "winning trader: +500");
        assertEq(collateral.balanceOf(alice), 1_000_000 - 500, "losing LP: -500 (zero-sum)");
    }

    /// @notice With fees, the post-resolution buffer == collectedFees: the market is strictly
    ///         OVER-collateralized against winning claims, and that surplus is the LP fee pot.
    function test_PostResolution_FeeBufferIsSolvent() public {
        _banner("test_PostResolution_FeeBufferIsSolvent");
        _seedFeeMarket(alice);
        _seedFeeMarket(bob);
        vm.prank(alice);
        market.addLiquidity(1000);
        vm.prank(bob);
        market.buy(PredictionMarket.Outcome.Yes, 1000, 0); // reserves 506/1980, fee 20, bob 1474 YES

        vm.warp(closeTime);
        vm.prank(resolver);
        market.resolve(PredictionMarket.Outcome.Yes);

        uint256 held = collateral.balanceOf(address(market));
        uint256 winningClaims = market.reserveYes() + market.yesBalanceOf(bob); // 506 + 1474 = 1980
        console2.log("held:", held, " winning claims:", winningClaims);
        console2.log("buffer (held - claims):", held - winningClaims, " collectedFees:", market.collectedFees());
        assertGe(held, winningClaims, "solvent against all winning claims");
        assertEq(held - winningClaims, market.collectedFees(), "the surplus is exactly the LP fee pot");
    }

    // ==============================================================================
    // Stage 8: hardening — audit finding #1 (JIT-liquidity fee theft)
    // A just-in-time LP that deposits AFTER fees have already accrued must NOT be able to
    // skim those pre-existing fees; it should earn only fees from trades that happen while
    // its shares are live. (feePoolWeight accumulator fix.)
    // ==============================================================================

    function test_Fee_JITLPCannotSkimPreAccruedFees() public {
        _banner("test_Fee_JITLPCannotSkimPreAccruedFees");
        _seedFeeMarket(alice); // honest LP
        _seedFeeMarket(bob); // trader
        _seedFeeMarket(carol); // JIT attacker

        // alice is the sole LP; bob trades, accruing 20 in fees BEFORE carol shows up.
        vm.prank(alice);
        market.addLiquidity(1000); // reserves 1000/1000, shares 1000
        vm.prank(bob);
        market.buy(PredictionMarket.Outcome.Yes, 1000, 0); // fee 20 -> collectedFees=20, reserves 506/1980
        assertEq(market.collectedFees(), 20, "fees accrued from bob's trade");

        uint256 carolStart = collateral.balanceOf(carol); // 1_000_000

        // carol JITs: add liquidity, immediately remove, then merge her residual matched set.
        vm.startPrank(carol);
        market.addLiquidity(1980); // mints 1000 shares (poolWeight=1980)
        market.removeLiquidity(market.sharesOf(carol));
        uint256 yc = market.yesBalanceOf(carol);
        uint256 nc = market.noBalanceOf(carol);
        uint256 set = yc < nc ? yc : nc; // matched complete set carol can merge back to collateral
        if (set > 0) market.merge(set);
        vm.stopPrank();
        _logActor("carol after JIT round-trip", carol, market);

        // FIX: carol made no profit — she joined AFTER the fee accrued.
        assertLe(collateral.balanceOf(carol), carolStart, "JIT LP must not profit from pre-accrued fees");
        // FIX: the honest LP's fees are intact and still fully claimable.
        assertEq(market.collectedFees(), 20, "pre-accrued fees stay with the honest LP");
    }

    // ==============================================================================
    // Stage 6a: stateless fuzz tests
    // Foundry calls each of these `runs` times (256, see foundry.toml) with random inputs.
    // We `bound()` inputs into safe ranges: reserves must stay small enough that the
    // product reserveYes * reserveNo can never overflow uint256 (~1.15e77). With every
    // amount <= 1e24, the largest product we can form is well under 1e49.
    // ==============================================================================

    /// @dev Upper bound for fuzzed amounts: keeps rY*rN far below uint256 max.
    uint256 internal constant FUZZ_MAX = 1e24;

    /// @notice split then merge is a perfect round-trip for ANY amount: collateral fully
    ///         restored, no outcome tokens left over.
    function testFuzz_SplitMergeRoundTrip(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        collateral.mint(alice, amount);
        vm.startPrank(alice);
        collateral.approve(address(market), amount);
        market.split(amount);
        assertEq(market.yesBalanceOf(alice), amount, "YES minted");
        assertEq(market.noBalanceOf(alice), amount, "NO minted");
        market.merge(amount);
        vm.stopPrank();
        assertEq(market.yesBalanceOf(alice), 0, "YES burned");
        assertEq(market.noBalanceOf(alice), 0, "NO burned");
        assertEq(collateral.balanceOf(alice), amount, "collateral fully restored");
        assertEq(collateral.balanceOf(address(market)), 0, "market emptied");
    }

    /// @notice The core solvency equation holds after ANY single funded buy on the fee market:
    ///         held == backing + collectedFees, and the two sides stay balanced (totalYES==totalNO).
    function testFuzz_BuyKeepsExactSolvency(uint256 fund, uint256 invest) public {
        fund = bound(fund, 1e3, FUZZ_MAX);
        invest = bound(invest, 1, FUZZ_MAX);

        collateral.mint(alice, fund);
        vm.startPrank(alice);
        collateral.approve(address(market), fund);
        market.addLiquidity(fund);
        vm.stopPrank();

        collateral.mint(bob, invest);
        vm.startPrank(bob);
        collateral.approve(address(market), invest);
        market.buy(PredictionMarket.Outcome.Yes, invest, 0);
        vm.stopPrank();

        uint256 totalYes = market.reserveYes() + market.yesBalanceOf(bob);
        uint256 totalNo = market.reserveNo() + market.noBalanceOf(bob);
        uint256 held = collateral.balanceOf(address(market));
        assertEq(totalYes, totalNo, "sets stay balanced (totalYES == totalNO)");
        assertEq(held, totalYes + market.collectedFees(), "held == backing + fees (exact)");
    }

    /// @notice YES price + NO price always sum to 1 (WAD) up to at most 1 wei of flooring.
    function testFuzz_PricesSumToWad(uint256 fund, uint256 invest) public {
        _setUpNoFeeMarket();
        fund = bound(fund, 1e3, FUZZ_MAX);
        invest = bound(invest, 0, FUZZ_MAX);

        collateral.mint(alice, fund);
        vm.prank(alice);
        mkt.addLiquidity(fund);

        if (invest > 0) {
            collateral.mint(bob, invest);
            vm.prank(bob);
            mkt.buy(PredictionMarket.Outcome.Yes, invest, 0);
        }

        uint256 sum = mkt.priceYes() + mkt.priceNo();
        // Each price floors independently, so the sum is WAD or WAD-1, never more, never less-by->1.
        assertLe(sum, mkt.WAD(), "prices never sum to more than 1");
        assertGe(sum, mkt.WAD() - 1, "prices sum to 1 within a single wei of flooring");
    }

    /// @notice Buying more collateral never returns fewer shares (the quote is monotonic).
    function testFuzz_CalcBuyMonotonic(uint256 fund, uint256 i1, uint256 i2) public {
        _setUpNoFeeMarket();
        fund = bound(fund, 1e3, FUZZ_MAX);
        i1 = bound(i1, 1, FUZZ_MAX);
        i2 = bound(i2, 1, FUZZ_MAX);
        if (i1 > i2) (i1, i2) = (i2, i1); // ensure i1 <= i2

        collateral.mint(alice, fund);
        vm.prank(alice);
        mkt.addLiquidity(fund);

        uint256 s1 = mkt.calcBuyAmount(PredictionMarket.Outcome.Yes, i1);
        uint256 s2 = mkt.calcBuyAmount(PredictionMarket.Outcome.Yes, i2);
        assertGe(s2, s1, "more investment never yields fewer shares");
    }
}
