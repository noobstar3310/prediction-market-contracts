// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title SimHighActivity
/// @notice A narrative simulation, NOT a pass/fail unit test. It seeds a thin 1,000 mUSDT pool,
///         unleashes ~300 pseudo-random trades from 8 retail traders, drops a 100,000 mUSDT whale
///         buy into the middle of it, then closes + resolves the market and settles everyone —
///         printing the price journey, volume, fees, and final P&L for every participant.
/// @dev Run it with logs:  forge test --match-contract SimHighActivity -vv
///      The randomness is a deterministic keccak chain (seeded), so the run is fully reproducible.
contract SimHighActivity is Test {
    PredictionMarket internal market;
    MockERC20 internal musdt;

    address internal lp = makeAddr("LP");
    address internal whale = makeAddr("WHALE");
    address internal feeVault = makeAddr("feeVault"); // all trading fees route here
    address[] internal traders;

    uint256 internal closeTime;
    uint16 internal constant FEE_BPS = 200; // 2%
    uint256 internal constant WAD = 1e18;

    uint256 internal constant N_TRADES = 300; // loop iterations (each may skip)
    uint256 internal constant WHALE_AT = 80; // inject the whale at this iteration

    // --- bookkeeping ---
    uint256 internal seed = 0xBEEF;
    uint256 internal totalBuyVolume;
    uint256 internal totalSellVolume;
    uint256 internal nBuys;
    uint256 internal nSells;
    uint256 internal nSplits;
    uint256 internal nMerges;
    uint256 internal nLPAdds;
    uint256 internal nSkipped;
    uint256 internal whaleShares;
    uint256 internal pricePeak; // highest YES price (cents) seen
    mapping(address => uint256) internal initialFunding;

    function setUp() public {
        musdt = new MockERC20("Mock USDT", "mUSDT");
        closeTime = block.timestamp + 30 days;
        // resolver = this test contract, so we can settle at the end.
        market = new PredictionMarket(musdt, address(this), closeTime, FEE_BPS, feeVault);

        for (uint256 i; i < 8; i++) {
            address t = makeAddr(string.concat("trader", vm.toString(i)));
            traders.push(t);
            _fund(t, 100_000e18);
        }
        _fund(lp, 1_000e18);
        _fund(whale, 100_000e18);
    }

    function _fund(address who, uint256 amt) internal {
        musdt.mint(who, amt);
        initialFunding[who] = amt;
        vm.prank(who);
        musdt.approve(address(market), type(uint256).max);
    }

    // =====================================================================================
    // The simulation
    // =====================================================================================

    function test_HighActivitySimulation() public {
        console2.log("=========================================================================");
        console2.log(" HIGH-ACTIVITY SIM | thin 1,000 mUSDT pool | 100k whale | ~300 trades");
        console2.log("=========================================================================");

        // --- LP seeds the thin pool: 1,000 mUSDT -> 50c, reserves 1000/1000 ---
        vm.prank(lp);
        market.addLiquidity(1_000e18);
        pricePeak = market.priceYes() / 1e16;
        console2.log("LP seeds 1,000 mUSDT. Starting price 50c.");
        _legend();
        _snap(0);

        // --- the trading storm ---
        for (uint256 i = 1; i <= N_TRADES; i++) {
            if (i == WHALE_AT) _whaleBuys();
            _step();

            uint256 p = market.priceYes() / 1e16;
            if (p > pricePeak) pricePeak = p;

            if (i % 30 == 0) _snap(i);
        }
        _snap(N_TRADES);

        uint256 feesGenerated = musdt.balanceOf(feeVault);
        uint256 finalPrice = market.priceYes() / 1e16;

        // --- close + resolve: YES wins ---
        console2.log("");
        console2.log("-------------------------------------------------------------------------");
        console2.log(" closeTime reached -> resolver declares YES the winner");
        console2.log("-------------------------------------------------------------------------");
        vm.warp(closeTime);
        market.resolve(PredictionMarket.Outcome.Yes);

        // --- settle everyone: pull liquidity, then redeem winning tokens ---
        address[] memory all = _all();
        for (uint256 i; i < all.length; i++) {
            uint256 s = market.s_sharesOf(all[i]);
            if (s > 0) {
                vm.prank(all[i]);
                try market.removeLiquidity(s) {} catch {}
            }
        }
        for (uint256 i; i < all.length; i++) {
            if (market.s_yesBalanceOf(all[i]) > 0) {
                vm.prank(all[i]);
                try market.redeem() {} catch {}
            }
        }

        // =====================================================================
        // Report
        // =====================================================================
        console2.log("");
        console2.log("============================ ACTIVITY ====================================");
        console2.log(string.concat("  successful buys   : ", vm.toString(nBuys)));
        console2.log(string.concat("  successful sells  : ", vm.toString(nSells)));
        console2.log(string.concat("  splits / merges   : ", vm.toString(nSplits), " / ", vm.toString(nMerges)));
        console2.log(string.concat("  extra LP adds     : ", vm.toString(nLPAdds)));
        console2.log(string.concat("  skipped attempts  : ", vm.toString(nSkipped)));
        console2.log(
            string.concat("  total trade volume: ", _usd(totalBuyVolume + totalSellVolume), " mUSDT (buys+sells)")
        );
        console2.log(string.concat("  fees generated    : ", _usd(feesGenerated), " mUSDT (all to vault)"));

        console2.log("");
        console2.log("============================ PRICE JOURNEY ===============================");
        console2.log("  start 50c  ->  peak after whale ~", vm.toString(pricePeak));
        console2.log(string.concat("  ...arbitraged back down to ", vm.toString(finalPrice), "c at close"));

        console2.log("");
        console2.log("============================ WHALE POST-MORTEM ===========================");
        console2.log(string.concat("  paid in            : 100,000 mUSDT for ", _usd(whaleShares), " YES shares"));
        console2.log(
            string.concat(
                "  avg price paid     : ", vm.toString(100_000e18 * 100 / whaleShares), "c per share (cap is 100c!)"
            )
        );
        console2.log(string.concat("  redeemed (YES won) : ", _usd(whaleShares), " mUSDT"));
        _pnl("  whale net P&L     ", whale);

        console2.log("");
        console2.log("============================ FINAL P&L ===================================");
        _pnl("LP (seeded 1,000) ", lp);
        int256 traderSum;
        for (uint256 i; i < traders.length; i++) {
            traderSum += int256(musdt.balanceOf(traders[i])) - int256(initialFunding[traders[i]]);
            _pnl(string.concat("trader", vm.toString(i), "          "), traders[i]);
        }
        console2.log(
            string.concat(
                "  traders combined  : ",
                traderSum >= 0 ? "+" : "-",
                _usd(uint256(traderSum >= 0 ? traderSum : -traderSum))
            )
        );

        console2.log("");
        console2.log("============================ SOLVENCY CHECK ==============================");
        uint256 dust = musdt.balanceOf(address(market));
        console2.log(string.concat("  collateral left in market after everyone exited: ", _usd(dust), " mUSDT"));
        console2.log("  (~0 = pool paid every winner in full; never insolvent)");
        // Zero-sum sanity: sum of ALL participant P&L should be ~0 (down to rounding dust).
        assertLe(dust, 1e18, "leftover collateral should be tiny rounding dust");
    }

    // =====================================================================================
    // One random step
    // =====================================================================================

    function _step() internal {
        uint256 r = _rnd(0, 99);
        if (r < 55) _doBuy();
        else if (r < 85) _doSell();
        else if (r < 93) _doSplit();
        else if (r < 97) _doMerge();
        else _doLPAdd();
    }

    function _doBuy() internal {
        address t = traders[_rnd(0, traders.length - 1)];
        uint256 bal = musdt.balanceOf(t);
        if (bal < 1e18) {
            nSkipped++;
            return;
        }
        uint256 amt = _rnd(1e18, _min(bal, 5_000e18));
        // 70% of the time traders chase value: buy whichever side is currently cheaper.
        // This is the arbitrage pressure that drags a distorted price back toward fair.
        bool cheaperIsYes = market.priceYes() < 5e17;
        PredictionMarket.Outcome o;
        if (_rnd(0, 99) < 70) {
            o = cheaperIsYes ? PredictionMarket.Outcome.Yes : PredictionMarket.Outcome.No;
        } else {
            o = _rnd(0, 1) == 0 ? PredictionMarket.Outcome.Yes : PredictionMarket.Outcome.No;
        }
        vm.prank(t);
        try market.buy(o, amt, 0) {
            nBuys++;
            totalBuyVolume += amt;
        } catch {
            nSkipped++;
        }
    }

    function _doSell() internal {
        address t = traders[_rnd(0, traders.length - 1)];
        uint256 yb = market.s_yesBalanceOf(t);
        uint256 nb = market.s_noBalanceOf(t);
        if (yb < 1e18 && nb < 1e18) {
            nSkipped++;
            return;
        }
        bool sellYes = yb >= nb;
        uint256 rOther = sellYes ? market.s_reserveNo() : market.s_reserveYes();
        if (rOther < 10e18) {
            nSkipped++;
            return;
        }
        uint256 ret = _rnd(1e18, rOther / 8); // keep returnAmount well under the opposite reserve
        PredictionMarket.Outcome o = sellYes ? PredictionMarket.Outcome.Yes : PredictionMarket.Outcome.No;
        vm.prank(t);
        try market.sell(o, ret, type(uint256).max) {
            nSells++;
            totalSellVolume += ret;
        } catch {
            nSkipped++;
        }
    }

    function _doSplit() internal {
        address t = traders[_rnd(0, traders.length - 1)];
        uint256 bal = musdt.balanceOf(t);
        if (bal < 1e18) {
            nSkipped++;
            return;
        }
        uint256 amt = _rnd(1e18, _min(bal, 2_000e18));
        vm.prank(t);
        try market.split(amt) {
            nSplits++;
        } catch {
            nSkipped++;
        }
    }

    function _doMerge() internal {
        address t = traders[_rnd(0, traders.length - 1)];
        uint256 m = _min(market.s_yesBalanceOf(t), market.s_noBalanceOf(t));
        if (m < 1e18) {
            nSkipped++;
            return;
        }
        uint256 amt = _rnd(1e18, m);
        vm.prank(t);
        try market.merge(amt) {
            nMerges++;
        } catch {
            nSkipped++;
        }
    }

    function _doLPAdd() internal {
        address t = traders[_rnd(0, traders.length - 1)];
        uint256 bal = musdt.balanceOf(t);
        if (bal < 1e18) {
            nSkipped++;
            return;
        }
        uint256 amt = _rnd(1e18, _min(bal, 3_000e18));
        vm.prank(t);
        try market.addLiquidity(amt) {
            nLPAdds++;
        } catch {
            nSkipped++;
        }
    }

    function _whaleBuys() internal {
        console2.log("");
        console2.log(">>>>>>>>>>>>>>>>> WHALE EVENT: dumps 100,000 mUSDT into YES <<<<<<<<<<<<<<<");
        uint256 before = market.priceYes() / 1e16;
        vm.prank(whale);
        market.buy(PredictionMarket.Outcome.Yes, 100_000e18, 0);
        whaleShares = market.s_yesBalanceOf(whale);
        totalBuyVolume += 100_000e18;
        nBuys++;
        console2.log(
            string.concat(
                "   YES price ", vm.toString(before), "c -> ", vm.toString(market.priceYes() / 1e16), "c (slammed up)"
            )
        );
        console2.log(
            string.concat(
                "   whale received ",
                _usd(whaleShares),
                " YES for 100,000 paid -> avg ",
                vm.toString(100_000e18 * 100 / whaleShares),
                "c/share"
            )
        );
        console2.log(
            string.concat(
                "   reserves now Y/N = ",
                _usd(market.s_reserveYes()),
                " / ",
                _usd(market.s_reserveNo()),
                " (YES side drained)"
            )
        );
        console2.log("");
    }

    // =====================================================================================
    // Helpers
    // =====================================================================================

    function _legend() internal pure {
        console2.log("snapshot = tx# | YES price | reserves YES/NO | cumulative volume | fees");
    }

    function _snap(uint256 i) internal view {
        console2.log(
            string.concat(
                "tx#",
                vm.toString(i),
                " | YES ",
                vm.toString(market.priceYes() / 1e16),
                "c",
                " | r ",
                _usd(market.s_reserveYes()),
                "/",
                _usd(market.s_reserveNo()),
                " | vol ",
                _usd(totalBuyVolume + totalSellVolume),
                " | fees ",
                _usd(musdt.balanceOf(feeVault))
            )
        );
    }

    function _pnl(string memory name, address a) internal view {
        uint256 fin = musdt.balanceOf(a);
        uint256 init = initialFunding[a];
        string memory sign = fin >= init ? "+" : "-";
        uint256 d = fin >= init ? fin - init : init - fin;
        console2.log(string.concat("  ", name, ": ", sign, _usd(d), " mUSDT"));
    }

    function _all() internal view returns (address[] memory out) {
        out = new address[](traders.length + 2);
        out[0] = lp;
        out[1] = whale;
        for (uint256 i; i < traders.length; i++) {
            out[i + 2] = traders[i];
        }
    }

    /// @dev Deterministic bounded pseudo-random in [lo, hi].
    function _rnd(uint256 lo, uint256 hi) internal returns (uint256) {
        seed = uint256(keccak256(abi.encode(seed)));
        return bound(seed, lo, hi);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev Format 1e18-scaled value as a "whole.cc" mUSDT string (2 decimals).
    function _usd(uint256 v) internal pure returns (string memory) {
        uint256 cents = (v % 1e18) / 1e16;
        string memory cc = cents < 10 ? string.concat("0", vm.toString(cents)) : vm.toString(cents);
        return string.concat(vm.toString(v / 1e18), ".", cc);
    }
}
