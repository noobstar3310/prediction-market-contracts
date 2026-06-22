// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title MultiOutcomeMarket
/// @notice A generalized N-outcome prediction market built as a constant-product AMM (CPMM).
///         It is a direct generalization of the binary `PredictionMarket`: where that contract
///         hardcodes two outcomes (YES/NO), this one supports any `outcomeSlotCount >= 2`, which
///         lets a SINGLE contract serve every poll type:
///
///           - BINARY      : 2 outcomes, resolved one-hot      e.g. payouts = [0, 1]
///           - CATEGORICAL : N outcomes, resolved one-hot      e.g. payouts = [0, 0, 1, 0]
///           - SCALAR      : 2 outcomes, resolved FRACTIONALLY e.g. payouts = [1, 1] (50/50),
///                           or [1, 3] for a value 3/4 of the way to the upper bound.
///
///         The unifying rule (borrowed from Gnosis ConditionalTokens) is that resolution is a
///         *payout-numerator vector*, not a single winner. A full set of all N outcome tokens is
///         always backed 1:1 by collateral, so the solvency invariant holds for every poll type.
/// @dev Supports ONLY standard, non-rebasing, non-fee-on-transfer ERC20s as collateral. A
///      fee-on-transfer token would break the 1:1 full-set backing and thus solvency.
///      For SCALAR markets, the resolver/front-end computes the fractional payout vector off-chain
///      from the market's bounds (e.g. payouts = [upper - final, final - lower]) and submits it to
///      `resolve`. This keeps the on-chain rule identical across all three poll types.
contract MultiOutcomeMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ----------------------------------------------------------------------------------
    // Constants
    // ----------------------------------------------------------------------------------

    /// @notice Basis-points denominator. 10_000 bps = 100%, so feeBps=200 means 2%.
    uint16 public constant FEE_DENOM = 10_000;

    /// @notice Fixed-point scale (1e18) for prices and for the CPMM's internal math.
    uint256 public constant WAD = 1e18;

    /// @notice Upper bound on outcomes. Trading math is overflow-safe at any N (it never forms the
    ///         full reserve product), but the `marginalPrice` view does, so we cap N to keep that
    ///         view usable and to bound per-call gas of the O(N) loops.
    uint256 public constant MAX_OUTCOMES = 256;

    // ----------------------------------------------------------------------------------
    // Immutable configuration
    // ----------------------------------------------------------------------------------

    /// @notice The ERC20 used as collateral / settlement currency.
    IERC20 public immutable collateral;

    /// @notice The only address allowed to resolve the market (submit the payout vector).
    address public immutable resolver;

    /// @notice Unix timestamp at/after which trading stops and resolution becomes possible.
    uint256 public immutable closeTime;

    /// @notice Trading fee in basis points (e.g. 200 = 2%), retained for liquidity providers.
    uint16 public immutable feeBps;

    /// @notice Number of outcome slots. 2 = binary/scalar, N = categorical. Immutable per market.
    uint256 public immutable outcomeSlotCount;

    // ----------------------------------------------------------------------------------
    // Mutable state
    // ----------------------------------------------------------------------------------

    /// @notice Pool reserves of each outcome token held by the AMM. Length == outcomeSlotCount.
    /// @dev The constant-product value k = ∏ reserves is intentionally NOT stored; the CPMM math
    ///      recomputes along the curve to avoid stale-k bugs.
    uint256[] public reserves;

    /// @notice Total LP shares minted; `sharesOf` is each provider's slice.
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    /// @notice Trading fees accumulated as bare collateral, claimable by LPs on removeLiquidity.
    uint256 public collectedFees;

    /// @notice Cumulative fees credited per LP share, scaled by WAD (MasterChef-style accumulator).
    uint256 public accFeePerShare;

    /// @notice Per-LP baseline so freshly-minted shares carry no claim on previously-accrued fees.
    mapping(address => uint256) public feeDebt;

    /// @notice Internal ledger of outcome tokens: balanceOf[outcomeIndex][account].
    mapping(uint256 => mapping(address => uint256)) public balanceOf;

    /// @notice Payout vector set at resolution: numerator per outcome. Length == outcomeSlotCount.
    /// @dev Empty until resolved. An outcome token of index i redeems for
    ///      `balance * payoutNumerators[i] / payoutDenominator` collateral.
    uint256[] public payoutNumerators;

    /// @notice Sum of payoutNumerators. Zero == unresolved; non-zero == resolved (the resolution flag).
    uint256 public payoutDenominator;

    // ----------------------------------------------------------------------------------
    // Events
    // ----------------------------------------------------------------------------------

    event Split(address indexed account, uint256 amount);
    event Merge(address indexed account, uint256 amount);
    event LiquidityAdded(address indexed provider, uint256 amount, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 shares, uint256 collateralOut);
    event Buy(address indexed buyer, uint256 indexed outcome, uint256 investmentAmount, uint256 sharesOut);
    event Sell(address indexed seller, uint256 indexed outcome, uint256 returnAmount, uint256 sharesIn);
    event Resolved(uint256[] payoutNumerators, uint256 payoutDenominator);
    event Redeemed(address indexed account, uint256 payout);

    // ----------------------------------------------------------------------------------
    // Errors
    // ----------------------------------------------------------------------------------

    error MultiOutcomeMarket__ZeroCollateral();
    error MultiOutcomeMarket__ZeroResolver();
    error MultiOutcomeMarket__CloseTimeInPast();
    error MultiOutcomeMarket__FeeTooHigh();
    error MultiOutcomeMarket__BadOutcomeCount();
    error MultiOutcomeMarket__ZeroAmount();
    error MultiOutcomeMarket__InvalidOutcome();
    error MultiOutcomeMarket__InsufficientBalance();
    error MultiOutcomeMarket__InsufficientShares();
    error MultiOutcomeMarket__PoolNotFunded();
    error MultiOutcomeMarket__TradingClosed();
    error MultiOutcomeMarket__SlippageExceeded();
    error MultiOutcomeMarket__ReturnTooHigh();
    error MultiOutcomeMarket__NotResolver();
    error MultiOutcomeMarket__NotClosed();
    error MultiOutcomeMarket__AlreadyResolved();
    error MultiOutcomeMarket__NotResolved();
    error MultiOutcomeMarket__BadPayoutVector();
    error MultiOutcomeMarket__NothingToRedeem();

    // ----------------------------------------------------------------------------------
    // Constructor
    // ----------------------------------------------------------------------------------

    /// @param collateral_       ERC20 collateral token address
    /// @param resolver_         address permitted to resolve the market
    /// @param closeTime_        timestamp at which trading ends (must be in the future)
    /// @param feeBps_           trading fee in basis points (must be < 100%)
    /// @param outcomeSlotCount_ number of outcomes (2 for binary/scalar, N for categorical)
    constructor(
        IERC20 collateral_,
        address resolver_,
        uint256 closeTime_,
        uint16 feeBps_,
        uint256 outcomeSlotCount_
    ) {
        if (address(collateral_) == address(0)) revert MultiOutcomeMarket__ZeroCollateral();
        if (resolver_ == address(0)) revert MultiOutcomeMarket__ZeroResolver();
        if (closeTime_ <= block.timestamp) revert MultiOutcomeMarket__CloseTimeInPast();
        if (feeBps_ >= FEE_DENOM) revert MultiOutcomeMarket__FeeTooHigh();
        if (outcomeSlotCount_ < 2 || outcomeSlotCount_ > MAX_OUTCOMES) {
            revert MultiOutcomeMarket__BadOutcomeCount();
        }

        collateral = collateral_;
        resolver = resolver_;
        closeTime = closeTime_;
        feeBps = feeBps_;
        outcomeSlotCount = outcomeSlotCount_;

        // Pre-size the reserve array so indices 0..n-1 are addressable (all start at 0 = unfunded).
        reserves = new uint256[](outcomeSlotCount_);
    }

    // ----------------------------------------------------------------------------------
    // Modifiers
    // ----------------------------------------------------------------------------------

    /// @notice Restrict a function to the trading window (before closeTime).
    modifier whenOpen() {
        if (block.timestamp >= closeTime) revert MultiOutcomeMarket__TradingClosed();
        _;
    }

    // ----------------------------------------------------------------------------------
    // Split / merge (the full-set backbone of solvency)
    // ----------------------------------------------------------------------------------

    /// @notice Deposit `amount` collateral and receive `amount` of EVERY outcome token.
    /// @dev Every full set minted is backed 1:1 by collateral now locked here — the solvency
    ///      invariant. Generalizes the binary split (mint YES+NO) to N outcomes.
    function split(uint256 amount) external nonReentrant {
        if (amount == 0) revert MultiOutcomeMarket__ZeroAmount();

        // ---- Effects (CEI): credit a unit of each outcome to the caller ----
        uint256 n = outcomeSlotCount;
        for (uint256 i = 0; i < n; i++) {
            balanceOf[i][msg.sender] += amount;
        }

        // ---- Interaction ----
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        emit Split(msg.sender, amount);
    }

    /// @notice Burn `amount` of EVERY outcome token and receive `amount` collateral back.
    /// @dev Inverse of split. A full set is worth exactly 1 collateral regardless of outcome,
    ///      so this is always safe.
    function merge(uint256 amount) external nonReentrant {
        if (amount == 0) revert MultiOutcomeMarket__ZeroAmount();

        uint256 n = outcomeSlotCount;
        // Verify the caller owns a full set before mutating anything.
        for (uint256 i = 0; i < n; i++) {
            if (balanceOf[i][msg.sender] < amount) revert MultiOutcomeMarket__InsufficientBalance();
        }
        // ---- Effects (CEI): burn the full set first ----
        for (uint256 i = 0; i < n; i++) {
            balanceOf[i][msg.sender] -= amount;
        }

        // ---- Interaction ----
        collateral.safeTransfer(msg.sender, amount);
        emit Merge(msg.sender, amount);
    }

    // ----------------------------------------------------------------------------------
    // Liquidity
    // ----------------------------------------------------------------------------------

    /// @notice Add liquidity and receive LP shares.
    /// @dev First funding seeds a uniform pool (every reserve == amount → equal prices). Subsequent
    ///      funding adds at the CURRENT price: shares scale with the largest reserve, every reserve
    ///      grows proportionally (prices preserved), and the surplus on the smaller (pricier) sides
    ///      is returned to the LP as outcome tokens. Generalizes the binary addLiquidity to N sides.
    function addLiquidity(uint256 amount) external nonReentrant whenOpen {
        if (amount == 0) revert MultiOutcomeMarket__ZeroAmount();
        uint256 n = outcomeSlotCount;

        uint256 sharesMinted;
        if (totalShares == 0) {
            // ---- First funding: uniform reserves, 1 share == 1 unit of depth ----
            for (uint256 i = 0; i < n; i++) {
                reserves[i] = amount;
            }
            sharesMinted = amount;
        } else {
            // poolWeight is the LARGEST reserve (the cheapest outcome) — the binding constraint.
            uint256 poolWeight = _maxReserve();
            sharesMinted = amount * totalShares / poolWeight; // round DOWN (pool's favor)

            for (uint256 i = 0; i < n; i++) {
                uint256 keep = amount * reserves[i] / poolWeight; // keep ratios → preserve prices
                reserves[i] += keep;
                // Surplus this deposit minted but the pool didn't keep is returned as an outcome token.
                balanceOf[i][msg.sender] += amount - keep;
            }
        }

        totalShares += sharesMinted;
        sharesOf[msg.sender] += sharesMinted;
        feeDebt[msg.sender] += sharesMinted * accFeePerShare / WAD;

        collateral.safeTransferFrom(msg.sender, address(this), amount);
        emit LiquidityAdded(msg.sender, amount, sharesMinted);
    }

    /// @notice Burn LP shares to withdraw a proportional slice of the pool + accrued fees.
    /// @dev Complete sets within the withdrawn reserves merge straight to collateral; any one-sided
    ///      remainder stays as the LP's residual outcome position. Allowed in any phase.
    function removeLiquidity(uint256 sharesToBurn) external nonReentrant {
        if (sharesToBurn == 0) revert MultiOutcomeMarket__ZeroAmount();
        if (sharesToBurn > sharesOf[msg.sender]) revert MultiOutcomeMarket__InsufficientShares();
        uint256 n = outcomeSlotCount;

        // This LP's proportional slice of each reserve, and the smallest such slice (the mergeable
        // complete-set amount common to all outcomes).
        uint256[] memory sendAmt = new uint256[](n);
        uint256 mergeable = type(uint256).max;
        for (uint256 i = 0; i < n; i++) {
            uint256 s = reserves[i] * sharesToBurn / totalShares; // round DOWN (pool's favor)
            sendAmt[i] = s;
            if (s < mergeable) mergeable = s;
        }

        uint256 feeShare = sharesOf[msg.sender] * accFeePerShare / WAD - feeDebt[msg.sender];

        // ---- Effects ----
        for (uint256 i = 0; i < n; i++) {
            reserves[i] -= sendAmt[i];
            // One-sided remainder (slice minus the mergeable complete set) → LP's residual position.
            balanceOf[i][msg.sender] += sendAmt[i] - mergeable;
        }
        collectedFees -= feeShare;
        sharesOf[msg.sender] -= sharesToBurn;
        totalShares -= sharesToBurn;
        feeDebt[msg.sender] = sharesOf[msg.sender] * accFeePerShare / WAD;

        uint256 collateralOut = mergeable + feeShare;

        // ---- Interaction ----
        collateral.safeTransfer(msg.sender, collateralOut);
        emit LiquidityRemoved(msg.sender, sharesToBurn, collateralOut);
    }

    // ----------------------------------------------------------------------------------
    // Pricing + trade quotes (N-reserve constant product — the Gnosis FPMM generalization)
    // ----------------------------------------------------------------------------------

    /// @notice Marginal price of `outcome`, scaled by WAD. All outcome prices sum to WAD.
    /// @dev price_i = (∏_{j != i} reserves[j]) / Σ_k (∏_{j != k} reserves[j]). For N=2 this equals
    ///      reserveOther / (reserveThis + reserveOther), matching the binary contract. This forms
    ///      reserve products, so it can overflow for large N / large reserves — it is a convenience
    ///      view only; front-ends may prefer to read `getReserves()` and price off-chain.
    function marginalPrice(uint256 outcome) external view returns (uint256) {
        if (totalShares == 0) revert MultiOutcomeMarket__PoolNotFunded();
        if (outcome >= outcomeSlotCount) revert MultiOutcomeMarket__InvalidOutcome();
        uint256 n = outcomeSlotCount;

        uint256 sumProducts = 0;
        uint256 targetProduct = 0;
        for (uint256 k = 0; k < n; k++) {
            uint256 prod = 1;
            for (uint256 j = 0; j < n; j++) {
                if (j != k) prod *= reserves[j];
            }
            sumProducts += prod;
            if (k == outcome) targetProduct = prod;
        }
        return targetProduct * WAD / sumProducts;
    }

    /// @notice How many `outcome` tokens a buyer receives for `investmentAmount` collateral.
    /// @dev Audited Gnosis FPMM form, computed iteratively so the full reserve product is never
    ///      materialized (overflow-safe). Buying `outcome` conceptually adds `x` (post-fee
    ///      investment) to every reserve, then pays out `outcome` tokens until ∏ reserves == k again.
    ///      Rounds sharesOut DOWN (pool's favor) via ceil-div of the retained balance.
    function calcBuyAmount(uint256 outcome, uint256 investmentAmount) public view returns (uint256) {
        if (totalShares == 0) revert MultiOutcomeMarket__PoolNotFunded();
        if (outcome >= outcomeSlotCount) revert MultiOutcomeMarket__InvalidOutcome();
        uint256 n = outcomeSlotCount;

        uint256 x = investmentAmount * (FEE_DENOM - feeBps) / FEE_DENOM; // net of fee
        uint256 endingBalance = reserves[outcome] * WAD;
        for (uint256 j = 0; j < n; j++) {
            if (j != outcome) {
                uint256 r = reserves[j];
                endingBalance = _ceilDiv(endingBalance * r, r + x);
            }
        }
        // sharesOut = (reserve_outcome + x) - newReserve_outcome
        return reserves[outcome] + x - _ceilDiv(endingBalance, WAD);
    }

    /// @notice How many `outcome` tokens a seller must return to receive `returnAmount` collateral.
    /// @dev Inverse FPMM form. `R` = returnAmount grossed up by the fee; the pool merges R complete
    ///      sets to source the payout, so every OTHER reserve must exceed R. Rounds sharesIn UP
    ///      (pool's favor).
    function calcSellAmount(uint256 outcome, uint256 returnAmount) public view returns (uint256) {
        if (totalShares == 0) revert MultiOutcomeMarket__PoolNotFunded();
        if (outcome >= outcomeSlotCount) revert MultiOutcomeMarket__InvalidOutcome();
        uint256 n = outcomeSlotCount;

        uint256 R = _ceilDiv(returnAmount * FEE_DENOM, FEE_DENOM - feeBps);
        uint256 endingBalance = reserves[outcome] * WAD;
        for (uint256 j = 0; j < n; j++) {
            if (j != outcome) {
                uint256 r = reserves[j];
                if (R >= r) revert MultiOutcomeMarket__ReturnTooHigh(); // pool can't pull R from this side
                endingBalance = _ceilDiv(endingBalance * r, r - R);
            }
        }
        // sharesIn = R + newReserve_outcome - reserve_outcome
        return R + _ceilDiv(endingBalance, WAD) - reserves[outcome];
    }

    // ----------------------------------------------------------------------------------
    // Buy / sell
    // ----------------------------------------------------------------------------------

    /// @notice Buy `outcome` tokens, reverting if you'd get fewer than `minSharesOut`.
    function buy(uint256 outcome, uint256 investmentAmount, uint256 minSharesOut)
        external
        nonReentrant
        whenOpen
    {
        if (investmentAmount == 0) revert MultiOutcomeMarket__ZeroAmount();
        if (outcome >= outcomeSlotCount) revert MultiOutcomeMarket__InvalidOutcome();
        if (totalShares == 0) revert MultiOutcomeMarket__PoolNotFunded();
        uint256 n = outcomeSlotCount;

        uint256 sharesOut = calcBuyAmount(outcome, investmentAmount);
        if (sharesOut < minSharesOut) revert MultiOutcomeMarket__SlippageExceeded();

        uint256 x = investmentAmount * (FEE_DENOM - feeBps) / FEE_DENOM;
        uint256 fee = investmentAmount - x;
        collectedFees += fee;
        accFeePerShare += fee * WAD / totalShares;

        // ---- Effects: every other reserve grows by x; the bought reserve nets +x - sharesOut ----
        for (uint256 i = 0; i < n; i++) {
            if (i == outcome) {
                reserves[i] = reserves[i] + x - sharesOut;
            } else {
                reserves[i] += x;
            }
        }
        balanceOf[outcome][msg.sender] += sharesOut;

        // ---- Interaction: pull the FULL investment (fee included) ----
        collateral.safeTransferFrom(msg.sender, address(this), investmentAmount);
        emit Buy(msg.sender, outcome, investmentAmount, sharesOut);
    }

    /// @notice Sell `outcome` tokens for collateral, reverting if it would cost more than `maxSharesIn`.
    function sell(uint256 outcome, uint256 returnAmount, uint256 maxSharesIn)
        external
        nonReentrant
        whenOpen
    {
        if (returnAmount == 0) revert MultiOutcomeMarket__ZeroAmount();
        if (outcome >= outcomeSlotCount) revert MultiOutcomeMarket__InvalidOutcome();
        if (totalShares == 0) revert MultiOutcomeMarket__PoolNotFunded();
        uint256 n = outcomeSlotCount;

        uint256 sharesIn = calcSellAmount(outcome, returnAmount);
        if (sharesIn > maxSharesIn) revert MultiOutcomeMarket__SlippageExceeded();
        if (balanceOf[outcome][msg.sender] < sharesIn) revert MultiOutcomeMarket__InsufficientBalance();

        uint256 R = _ceilDiv(returnAmount * FEE_DENOM, FEE_DENOM - feeBps);
        uint256 fee = R - returnAmount;
        collectedFees += fee;
        accFeePerShare += fee * WAD / totalShares;

        // ---- Effects: seller's tokens enter the sold reserve; pool merges R sets out of all sides ----
        balanceOf[outcome][msg.sender] -= sharesIn;
        for (uint256 i = 0; i < n; i++) {
            if (i == outcome) {
                reserves[i] = reserves[i] + sharesIn - R;
            } else {
                reserves[i] -= R;
            }
        }

        // ---- Interaction: pay the NET return (fee stays in the contract) ----
        collateral.safeTransfer(msg.sender, returnAmount);
        emit Sell(msg.sender, outcome, returnAmount, sharesIn);
    }

    // ----------------------------------------------------------------------------------
    // Resolution + redemption (the unified payout-vector rule)
    // ----------------------------------------------------------------------------------

    /// @notice Submit the payout-numerator vector. Callable ONCE, only by the resolver, only after
    ///         closeTime. This single function settles every poll type:
    ///           - binary winner YES        : [0, 1]
    ///           - categorical winner C (of 4): [0, 0, 1, 0]
    ///           - scalar final value v      : [upper - v, v - lower] (or any ratio summing > 0)
    /// @dev Mirrors Gnosis ConditionalTokens.reportPayouts. The denominator is the sum of numerators;
    ///      a non-zero denominator is the "resolved" flag. No external call → no nonReentrant needed.
    /// @param payouts numerator per outcome; length must equal outcomeSlotCount; sum must be > 0.
    function resolve(uint256[] calldata payouts) external {
        if (msg.sender != resolver) revert MultiOutcomeMarket__NotResolver();
        if (block.timestamp < closeTime) revert MultiOutcomeMarket__NotClosed();
        if (payoutDenominator != 0) revert MultiOutcomeMarket__AlreadyResolved();
        if (payouts.length != outcomeSlotCount) revert MultiOutcomeMarket__BadPayoutVector();

        uint256 den = 0;
        for (uint256 i = 0; i < payouts.length; i++) {
            den += payouts[i];
        }
        if (den == 0) revert MultiOutcomeMarket__BadPayoutVector(); // all-zero is not a valid result

        payoutNumerators = payouts; // copy calldata vector into storage
        payoutDenominator = den;
        emit Resolved(payouts, den);
    }

    /// @notice After resolution, burn ALL your outcome tokens for their fractional collateral value.
    /// @dev payout = Σ_i balance_i * payoutNumerators[i] / payoutDenominator. For a one-hot result
    ///      this is winner-take-all; for a scalar result both sides pay out proportionally. Solvency:
    ///      every token came from a full set (each backed by 1 collateral), and the payout fractions
    ///      across a full set sum to exactly 1, so the contract can always pay every holder in full.
    function redeem() external nonReentrant {
        if (payoutDenominator == 0) revert MultiOutcomeMarket__NotResolved();
        uint256 n = outcomeSlotCount;
        uint256 den = payoutDenominator;

        // ---- Effects: tally and zero every outcome balance before paying (CEI) ----
        uint256 totalPayout = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 bal = balanceOf[i][msg.sender];
            if (bal > 0) {
                totalPayout += bal * payoutNumerators[i] / den; // round DOWN (pool's favor)
                balanceOf[i][msg.sender] = 0;
            }
        }
        if (totalPayout == 0) revert MultiOutcomeMarket__NothingToRedeem();

        // ---- Interaction ----
        collateral.safeTransfer(msg.sender, totalPayout);
        emit Redeemed(msg.sender, totalPayout);
    }

    // ----------------------------------------------------------------------------------
    // Views + internal helpers
    // ----------------------------------------------------------------------------------

    /// @notice Returns the full reserve array (safe for front-ends to price off-chain).
    function getReserves() external view returns (uint256[] memory) {
        return reserves;
    }

    /// @notice Returns the full payout vector (empty until resolved).
    function getPayoutNumerators() external view returns (uint256[] memory) {
        return payoutNumerators;
    }

    /// @dev Largest current reserve (the binding constraint for proportional funding).
    function _maxReserve() internal view returns (uint256 m) {
        uint256 n = outcomeSlotCount;
        for (uint256 i = 0; i < n; i++) {
            if (reserves[i] > m) m = reserves[i];
        }
    }

    /// @dev Ceiling division: smallest integer >= a/b. Used to round trade math in the pool's favor.
    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }
}
