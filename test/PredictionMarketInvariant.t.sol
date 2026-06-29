// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title Handler
/// @notice The "fuzzer's hands". Foundry's invariant engine calls these functions in random
///         order with random arguments (a random *sequence* of actions). Each function pranks
///         as one of a small fixed set of actors and performs one market operation, bounding its
///         inputs into safe/valid ranges so a useful fraction of calls actually succeed.
/// @dev We wrap the market calls in try/catch so an individual revert (e.g. selling more than you
///      own) is simply ignored — the engine then re-checks the invariant and moves on. Reads of
///      market state are done BEFORE vm.prank, because vm.prank only affects the very next call.
contract Handler is Test {
    PredictionMarket internal immutable market;
    MockERC20 internal immutable collateral;
    address internal immutable resolver;
    uint256 internal immutable closeTime;

    /// @dev The only addresses that ever hold tokens/shares. The invariant sums over exactly
    ///      these (plus the pool reserves) to reconstruct total supply.
    address[] internal actors;

    /// @dev Keep every fuzzed amount <= 1e24 so reserveYes*reserveNo can never overflow uint256.
    uint256 internal constant MAXAMT = 1e24;

    constructor(PredictionMarket _market, MockERC20 _collateral, uint256 _closeTime, address _resolver) {
        market = _market;
        collateral = _collateral;
        closeTime = _closeTime;
        resolver = _resolver;

        actors.push(makeAddr("h_alice"));
        actors.push(makeAddr("h_bob"));
        actors.push(makeAddr("h_carol"));
        for (uint256 i; i < actors.length; i++) {
            collateral.mint(actors[i], 1e30); // plenty of collateral for any sequence
            vm.prank(actors[i]);
            collateral.approve(address(market), type(uint256).max);
        }
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // ---- the eight random actions the roadmap calls for ----

    function split(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        uint256 amt = bound(amount, 1, MAXAMT);
        vm.prank(a);
        try market.split(amt) {} catch {}
    }

    function merge(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        uint256 m = _min(market.s_yesBalanceOf(a), market.s_noBalanceOf(a));
        if (m == 0) return;
        uint256 amt = bound(amount, 1, m);
        vm.prank(a);
        try market.merge(amt) {} catch {}
    }

    function addLiquidity(uint256 seed, uint256 amount) external {
        if (block.timestamp >= closeTime) return; // whenOpen would reject it
        address a = _actor(seed);
        uint256 amt = bound(amount, 1, MAXAMT);
        vm.prank(a);
        try market.addLiquidity(amt) {} catch {}
    }

    function removeLiquidity(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        uint256 s = market.s_sharesOf(a);
        if (s == 0) return;
        uint256 amt = bound(amount, 1, s);
        vm.prank(a);
        try market.removeLiquidity(amt) {} catch {}
    }

    function buy(uint256 seed, bool yes, uint256 amount) external {
        if (market.s_totalShares() == 0) return; // PoolNotFunded otherwise
        if (block.timestamp >= closeTime) return;
        address a = _actor(seed);
        uint256 amt = bound(amount, 1, MAXAMT);
        PredictionMarket.Outcome o = yes ? PredictionMarket.Outcome.Yes : PredictionMarket.Outcome.No;
        vm.prank(a);
        try market.buy(o, amt, 0) {} catch {}
    }

    function sell(uint256 seed, bool yes, uint256 amount) external {
        if (block.timestamp >= closeTime) return;
        address a = _actor(seed);
        uint256 bal = yes ? market.s_yesBalanceOf(a) : market.s_noBalanceOf(a);
        if (bal == 0) return;
        uint256 rOther = yes ? market.s_reserveNo() : market.s_reserveYes();
        if (rOther <= 1) return;
        uint256 ret = bound(amount, 1, rOther - 1); // returnAmount must be < opposite reserve
        PredictionMarket.Outcome o = yes ? PredictionMarket.Outcome.Yes : PredictionMarket.Outcome.No;
        vm.prank(a);
        // May still revert (fee grosses R up past rOther, or sharesIn > bal) — that's fine.
        try market.sell(o, ret, type(uint256).max) {} catch {}
    }

    function resolve(bool yes) external {
        if (market.s_winningOutcome() != PredictionMarket.Outcome.Unset) return; // resolve once
        vm.warp(closeTime); // can only resolve at/after closeTime
        PredictionMarket.Outcome o = yes ? PredictionMarket.Outcome.Yes : PredictionMarket.Outcome.No;
        vm.prank(resolver);
        try market.resolve(o) {} catch {}
    }

    function redeem(uint256 seed) external {
        if (market.s_winningOutcome() == PredictionMarket.Outcome.Unset) return;
        address a = _actor(seed);
        vm.prank(a);
        try market.redeem() {} catch {}
    }
}

/// @title PredictionMarketInvariantTest
/// @notice Stateful invariant test: after EVERY call in EVERY random sequence the engine builds,
///         Foundry re-runs the `invariant_*` functions and fails if any assertion breaks.
contract PredictionMarketInvariantTest is StdInvariant, Test {
    MockERC20 internal collateral;
    PredictionMarket internal market;
    Handler internal handler;
    address internal resolver = makeAddr("inv_resolver");
    address internal feeVault = makeAddr("inv_feeVault");
    uint256 internal closeTime;

    function setUp() public {
        collateral = new MockERC20("Mock USDT", "mUSDT");
        closeTime = block.timestamp + 7 days;
        market = new PredictionMarket(collateral, resolver, closeTime, 200, feeVault); // 2% fee
        handler = new Handler(market, collateral, closeTime, resolver);

        // Restrict the fuzzer to ONLY the handler's eight action selectors. (Without this it would
        // also try to call the inherited forge-std helper functions on the handler.)
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = Handler.split.selector;
        selectors[1] = Handler.merge.selector;
        selectors[2] = Handler.addLiquidity.selector;
        selectors[3] = Handler.removeLiquidity.selector;
        selectors[4] = Handler.buy.selector;
        selectors[5] = Handler.sell.selector;
        selectors[6] = Handler.resolve.selector;
        selectors[7] = Handler.redeem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Reconstruct total supply by summing the pool reserves and every actor's balance.
    function _totals() internal view returns (uint256 totalYes, uint256 totalNo, uint256 totalActorShares) {
        totalYes = market.s_reserveYes();
        totalNo = market.s_reserveNo();
        address[] memory actors = handler.getActors();
        for (uint256 i; i < actors.length; i++) {
            totalYes += market.s_yesBalanceOf(actors[i]);
            totalNo += market.s_noBalanceOf(actors[i]);
            totalActorShares += market.s_sharesOf(actors[i]);
        }
    }

    /// @notice THE solvency invariant — must hold after every single call, in every phase.
    ///   Pre-resolution : sets stay balanced (totalYES == totalNO) and held == totalYES.
    ///   Post-resolution: held == supply of the winning side.
    /// Fees are routed to the vault on every trade, so the market holds NO fee buffer — its
    /// collateral balance exactly equals the claims it still owes. It can never become insolvent.
    function invariant_Solvency() public view {
        (uint256 totalYes, uint256 totalNo,) = _totals();
        uint256 held = collateral.balanceOf(address(market));

        if (market.s_winningOutcome() == PredictionMarket.Outcome.Unset) {
            assertEq(totalYes, totalNo, "pre-resolution: sets balanced");
            assertEq(held, totalYes, "pre-resolution: held == backing (no fee buffer)");
        } else {
            uint256 winning = market.s_winningOutcome() == PredictionMarket.Outcome.Yes ? totalYes : totalNo;
            assertEq(held, winning, "post-resolution: held == winning claims (no fee buffer)");
        }
    }

    /// @notice LP-share accounting can never drift: the sum of every holder's shares equals
    ///         totalShares.
    function invariant_SharesSumToTotal() public view {
        (,, uint256 totalActorShares) = _totals();
        assertEq(totalActorShares, market.s_totalShares(), "sum(sharesOf) == totalShares");
    }
}
