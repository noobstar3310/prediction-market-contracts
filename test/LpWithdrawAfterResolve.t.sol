// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title LpWithdrawAfterResolve
/// @notice Didactic walk-through: an LP seeds a pool, ONE trader takes a directional bet, the
///         market resolves, then the LP withdraws. It prints the FULL withdrawal breakdown
///         (merged collateral + redeemed winning tokens + worthless losing tokens; fees go to the
///         vault, NOT the LP) and the net profit/loss. Two mirror scenarios, same 3,000 trade size:
///           A) trader bets the WINNING side  -> LP loses (adverse selection / divergence loss)
///           B) trader bets the LOSING  side  -> LP profits (pockets the loser's stake; no fees)
/// @dev Run:  forge test --match-contract LpWithdrawAfterResolve -vv
contract LpWithdrawAfterResolve is Test {
    MockERC20 internal musdt;
    PredictionMarket internal market;

    address internal lp = makeAddr("LP");
    address internal trader = makeAddr("TRADER");
    address internal feeVault = makeAddr("feeVault"); // all trading fees route here

    uint256 internal closeTime;
    uint16 internal constant FEE_BPS = 200; // 2%
    uint256 internal constant DEPOSIT = 1_000e18;
    uint256 internal constant BET = 3_000e18;

    function _fresh() internal {
        musdt = new MockERC20("Mock USDT", "mUSDT");
        closeTime = block.timestamp + 7 days;
        market = new PredictionMarket(musdt, address(this), closeTime, FEE_BPS, feeVault); // resolver = this
        _fund(lp, 1_000_000e18);
        _fund(trader, 1_000_000e18);
    }

    function _fund(address a, uint256 amt) internal {
        musdt.mint(a, amt);
        vm.prank(a);
        musdt.approve(address(market), type(uint256).max);
    }

    // =====================================================================================
    // Scenario A: trader buys the WINNING side -> LP loses
    // =====================================================================================
    function test_A_TraderBetsWinningSide_LpLoses() public {
        _fresh();
        console2.log("########################################################################");
        console2.log("# SCENARIO A: trader buys YES (3,000), YES wins -> counterparty was RIGHT");
        console2.log("########################################################################");

        vm.prank(lp);
        market.addLiquidity(DEPOSIT);
        console2.log("LP deposits 1,000 -> reserves 1000/1000, price 50c");

        vm.prank(trader);
        market.buy(PredictionMarket.Outcome.Yes, BET, 0);
        console2.log(
            string.concat(
                "Trader buys YES with 3,000 -> got ",
                _usd(market.s_yesBalanceOf(trader)),
                " YES; price now ",
                vm.toString(market.priceYes() / 1e16),
                "c"
            )
        );

        vm.warp(closeTime);
        market.resolve(PredictionMarket.Outcome.Yes);
        console2.log("Resolved: YES wins");
        console2.log("");

        _withdrawAndReport(PredictionMarket.Outcome.Yes);
    }

    // =====================================================================================
    // Scenario B: trader buys the LOSING side -> LP profits
    // =====================================================================================
    function test_B_TraderBetsLosingSide_LpProfits() public {
        _fresh();
        console2.log("########################################################################");
        console2.log("# SCENARIO B: trader buys NO (3,000), YES wins -> counterparty was WRONG");
        console2.log("########################################################################");

        vm.prank(lp);
        market.addLiquidity(DEPOSIT);
        console2.log("LP deposits 1,000 -> reserves 1000/1000, price 50c");

        vm.prank(trader);
        market.buy(PredictionMarket.Outcome.No, BET, 0);
        console2.log(
            string.concat(
                "Trader buys NO with 3,000 -> got ",
                _usd(market.s_noBalanceOf(trader)),
                " NO; YES price now ",
                vm.toString(market.priceYes() / 1e16),
                "c"
            )
        );

        vm.warp(closeTime);
        market.resolve(PredictionMarket.Outcome.Yes);
        console2.log("Resolved: YES wins (trader's NO is now worthless)");
        console2.log("");

        _withdrawAndReport(PredictionMarket.Outcome.Yes);
    }

    // =====================================================================================
    // The shared withdrawal + reporting logic
    // =====================================================================================
    function _withdrawAndReport(PredictionMarket.Outcome winning) internal {
        // Fees were routed to the vault on the trade — the LP receives NONE of them.
        uint256 vaultFees = musdt.balanceOf(feeVault);

        uint256 shares = market.s_sharesOf(lp);
        uint256 balBefore = musdt.balanceOf(lp);

        // --- STEP 1: removeLiquidity -> pays merged complete sets as collateral (NO fees),
        //     and credits one-sided leftover reserves as outcome tokens ---
        vm.prank(lp);
        market.removeLiquidity(shares);
        uint256 mergedCollateral = musdt.balanceOf(lp) - balBefore;

        uint256 leftYes = market.s_yesBalanceOf(lp);
        uint256 leftNo = market.s_noBalanceOf(lp);

        // --- STEP 2: redeem the leftover IF it's on the winning side ---
        uint256 winningLeftover = winning == PredictionMarket.Outcome.Yes ? leftYes : leftNo;
        uint256 losingLeftover = winning == PredictionMarket.Outcome.Yes ? leftNo : leftYes;
        uint256 fromRedeem;
        if (winningLeftover > 0) {
            uint256 pre = musdt.balanceOf(lp);
            vm.prank(lp);
            market.redeem();
            fromRedeem = musdt.balanceOf(lp) - pre;
        }

        uint256 totalReturned = musdt.balanceOf(lp) - balBefore;

        // ---- report ----
        console2.log("============ LP WITHDRAWAL AFTER RESOLUTION ============");
        console2.log(string.concat("  Capital originally deposited : ", _usd(DEPOSIT), " mUSDT"));
        console2.log(string.concat("  (fees routed to vault, NOT LP): ", _usd(vaultFees), " mUSDT"));
        console2.log("  -------------------------------------------------");
        console2.log("  STEP 1  removeLiquidity():");
        console2.log(string.concat("    collateral from merged sets: ", _usd(mergedCollateral), " mUSDT"));
        console2.log(
            string.concat(
                "    + leftover outcome tokens  : ",
                _usd(winningLeftover + losingLeftover),
                " (",
                _usd(winningLeftover),
                " winning / ",
                _usd(losingLeftover),
                " worthless)"
            )
        );
        console2.log("  STEP 2  redeem() winning leftover:");
        console2.log(string.concat("    winning tokens -> collateral: ", _usd(fromRedeem), " mUSDT"));
        console2.log(string.concat("    worthless tokens discarded  : ", _usd(losingLeftover), " -> $0"));
        console2.log("  =================================================");
        console2.log(string.concat("  TOTAL CAPITAL RETURNED       : ", _usd(totalReturned), " mUSDT"));
        _pnl(totalReturned, DEPOSIT);
        console2.log("");
    }

    function _pnl(uint256 returned, uint256 deposited) internal pure {
        if (returned >= deposited) {
            console2.log(
                string.concat("  PROFIT / LOSS                : +", _usd(returned - deposited), " mUSDT  (profit)")
            );
        } else {
            console2.log(
                string.concat("  PROFIT / LOSS                : -", _usd(deposited - returned), " mUSDT  (loss)")
            );
        }
    }

    /// @dev Format a 1e18-scaled value as "whole.cc".
    function _usd(uint256 v) internal pure returns (string memory) {
        uint256 cents = (v % 1e18) / 1e16;
        string memory cc = cents < 10 ? string.concat("0", vm.toString(cents)) : vm.toString(cents);
        return string.concat(vm.toString(v / 1e18), ".", cc);
    }
}
