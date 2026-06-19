// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PredictionMarket
/// @notice A binary (YES/NO) prediction market built as a constant-product AMM (CPMM).
///         Outcome tokens are tracked in an internal ledger (mappings), liquidity is
///         provided by multiple LPs who share trading fees, and a trusted resolver
///         settles the market after it closes. Design lineage: Gnosis
///         FixedProductMarketMaker (buy/sell/fund math) + ConditionalTokens (split/merge).
/// @dev Supports ONLY standard, non-rebasing, non-fee-on-transfer, 18-decimal ERC20s as
///      collateral. A fee-on-transfer token would break the 1:1 full-set backing and thus
///      the solvency invariant.
contract PredictionMarket is ReentrancyGuard {
    // `using SafeERC20 for IERC20` attaches SafeERC20's helper functions (safeTransfer,
    // safeTransferFrom) onto any IERC20 value, so we can write `collateral.safeTransfer(...)`.
    // SafeERC20 handles tokens that don't return a bool (e.g. USDT) and reverts on failure.
    using SafeERC20 for IERC20;

    // ----------------------------------------------------------------------------------
    // Types
    // ----------------------------------------------------------------------------------

    /// @notice Lifecycle of the market.
    /// Open     = trading + liquidity allowed (before closeTime)
    /// Closed   = past closeTime, awaiting resolution (no trading)
    /// Resolved = resolver has declared the winner; redemption enabled
    enum Status {
        Open,
        Closed,
        Resolved
    }

    /// @notice The two outcomes, plus a sentinel `Unset` so we can tell "not yet resolved"
    ///         apart from a real outcome. (If the winner were a plain bool, we couldn't
    ///         distinguish "NO won" from "nobody has resolved yet".)
    enum Outcome {
        Unset,
        Yes,
        No
    }

    // ----------------------------------------------------------------------------------
    // Immutable configuration (set once in the constructor, then can never change)
    // ----------------------------------------------------------------------------------

    /// @notice Basis-points denominator. 10_000 bps = 100%, so feeBps=200 means 2%.
    uint16 public constant FEE_DENOM = 10_000;

    /// @notice Fixed-point scale (1e18) used to express prices as integers, since Solidity
    ///         has no decimals. A price of 0.80 is returned as 0.80 * WAD = 8e17. This scale
    ///         is independent of the collateral's own decimals (a price is a pure ratio).
    uint256 public constant WAD = 1e18;

    /// @notice The ERC20 used as collateral / settlement currency (e.g. mock USDC).
    IERC20 public immutable collateral;

    /// @notice The only address allowed to resolve the market (declare the winner).
    address public immutable resolver;

    /// @notice Unix timestamp at/after which trading stops and resolution becomes possible.
    uint256 public immutable closeTime;

    /// @notice Trading fee in basis points (e.g. 200 = 2%), charged on each buy/sell and
    ///         retained for liquidity providers.
    uint16 public immutable feeBps;

    // ----------------------------------------------------------------------------------
    // Mutable state (filled in by later stages)
    // ----------------------------------------------------------------------------------

    /// @notice Pool reserves of YES and NO outcome tokens held by the AMM.
    /// @dev The constant-product value k = reserveYes * reserveNo is intentionally NOT
    ///      stored; we recompute it on demand to avoid stale-k bugs.
    uint256 public reserveYes;
    uint256 public reserveNo;

    /// @notice Total LP shares minted; `sharesOf` is each provider's slice. Together they
    ///         act as an internal "LP token" representing a claim on the pool.
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    /// @notice Internal ledger of outcome tokens owned by each user (not ERC20s).
    mapping(address => uint256) public yesBalanceOf;
    mapping(address => uint256) public noBalanceOf;

    /// @notice The winning outcome; stays `Unset` until the resolver calls resolve().
    Outcome public winningOutcome;

    // ----------------------------------------------------------------------------------
    // Events
    // ----------------------------------------------------------------------------------

    /// @notice Emitted when `account` splits `amount` collateral into `amount` YES + NO.
    /// @dev `indexed` lets off-chain tools filter logs by account efficiently.
    event Split(address indexed account, uint256 amount);

    /// @notice Emitted when `account` merges `amount` YES + NO back into `amount` collateral.
    event Merge(address indexed account, uint256 amount);

    /// @notice Emitted when `provider` adds `amount` collateral of liquidity and is minted `shares`.
    event LiquidityAdded(address indexed provider, uint256 amount, uint256 shares);

    /// @notice Emitted on a buy: `buyer` spent `investmentAmount` collateral for `sharesOut`
    ///         tokens of `outcome`.
    event Buy(address indexed buyer, Outcome outcome, uint256 investmentAmount, uint256 sharesOut);

    /// @notice Emitted on a sell: `seller` returned `sharesIn` tokens of `outcome` for
    ///         `returnAmount` collateral.
    event Sell(address indexed seller, Outcome outcome, uint256 returnAmount, uint256 sharesIn);

    // ----------------------------------------------------------------------------------
    // Errors
    // ----------------------------------------------------------------------------------
    // Custom errors (Solidity >=0.8.4) replace `require(cond, "string")`. They compile to a
    // 4-byte selector instead of storing a string, so they are cheaper to deploy and to
    // revert with, and they can optionally carry parameters (e.g. `error PredictionMarket__FeeTooHigh(uint16)`).

    /// @notice Constructor was given the zero address for the collateral token.
    error PredictionMarket__ZeroCollateral();
    /// @notice Constructor was given the zero address for the resolver.
    error PredictionMarket__ZeroResolver();
    /// @notice closeTime must be strictly in the future at deployment.
    error PredictionMarket__CloseTimeInPast();
    /// @notice feeBps must be below 100% (FEE_DENOM).
    error PredictionMarket__FeeTooHigh();
    /// @notice An amount argument was zero where a positive value is required.
    error PredictionMarket__ZeroAmount();
    /// @notice Caller does not own enough YES tokens for this operation.
    error PredictionMarket__InsufficientYes();
    /// @notice Caller does not own enough NO tokens for this operation.
    error PredictionMarket__InsufficientNo();
    /// @notice Operation requires a funded pool, but no liquidity has been added yet.
    error PredictionMarket__PoolNotFunded();
    /// @notice First funding already happened; multi-LP funding arrives in Stage 4.
    error PredictionMarket__AlreadyFunded();
    /// @notice Outcome argument must be Yes or No (not the Unset sentinel).
    error PredictionMarket__InvalidOutcome();
    /// @notice Trading is no longer allowed because the market has reached closeTime.
    error PredictionMarket__TradingClosed();
    /// @notice The trade's result was worse than the caller's slippage limit.
    error PredictionMarket__SlippageExceeded();
    /// @notice Requested collateral-out on a sell is too large for the pool to honor.
    error PredictionMarket__ReturnTooHigh();

    // ----------------------------------------------------------------------------------
    // Constructor
    // ----------------------------------------------------------------------------------

    /// @param collateral_ ERC20 collateral token address
    /// @param resolver_   address permitted to resolve the market
    /// @param closeTime_  timestamp at which trading ends (must be in the future)
    /// @param feeBps_     trading fee in basis points (must be < 100%)
    constructor(IERC20 collateral_, address resolver_, uint256 closeTime_, uint16 feeBps_) {
        // Validate inputs up front so a market can never be created in a broken state.
        // Pattern: check the *failure* condition, then `revert` with a named error.
        if (address(collateral_) == address(0)) revert PredictionMarket__ZeroCollateral();
        if (resolver_ == address(0)) revert PredictionMarket__ZeroResolver();
        if (closeTime_ <= block.timestamp) revert PredictionMarket__CloseTimeInPast();
        if (feeBps_ >= FEE_DENOM) revert PredictionMarket__FeeTooHigh();

        // Persist configuration into immutables (cheap to read, impossible to mutate later).
        collateral = collateral_;
        resolver = resolver_;
        closeTime = closeTime_;
        feeBps = feeBps_;
    }

    // ----------------------------------------------------------------------------------
    // Stage 1: split / merge (the "full set" backbone of solvency)
    // ----------------------------------------------------------------------------------

    /// @notice Deposit `amount` collateral and receive `amount` YES + `amount` NO tokens.
    /// @dev This is the ONLY way new outcome tokens come into existence, and every set
    ///      minted is backed 1:1 by collateral now locked in this contract. That backing
    ///      is the solvency invariant.
    /// @param amount units of collateral to convert into a full set
    function split(uint256 amount) external nonReentrant {
        if (amount == 0) revert PredictionMarket__ZeroAmount();

        // ---- Effects: update our internal ledger BEFORE the external token call (CEI) ----
        // Mint a matching pair into the caller's outcome balances.
        yesBalanceOf[msg.sender] += amount;
        noBalanceOf[msg.sender] += amount;

        // ---- Interaction: pull the collateral in last ----
        // safeTransferFrom moves `amount` from the caller to this contract. It requires the
        // caller to have approved this contract first, and reverts if the transfer fails.
        collateral.safeTransferFrom(msg.sender, address(this), amount);

        emit Split(msg.sender, amount);
    }

    /// @notice Burn `amount` YES + `amount` NO and receive `amount` collateral back.
    /// @dev The inverse of split. Because a full set is worth exactly 1 collateral
    ///      regardless of the eventual outcome, this redemption is always safe.
    /// @param amount size of the full set to merge back into collateral
    function merge(uint256 amount) external nonReentrant {
        if (amount == 0) revert PredictionMarket__ZeroAmount();
        // The caller must actually own a full set of this size. Solidity 0.8 reverts on
        // underflow anyway, but explicit checks give clearer, named errors.
        if (yesBalanceOf[msg.sender] < amount) revert PredictionMarket__InsufficientYes();
        if (noBalanceOf[msg.sender] < amount) revert PredictionMarket__InsufficientNo();

        // ---- Effects: burn the set from the ledger first (CEI) ----
        yesBalanceOf[msg.sender] -= amount;
        noBalanceOf[msg.sender] -= amount;

        // ---- Interaction: release the collateral last ----
        collateral.safeTransfer(msg.sender, amount);

        emit Merge(msg.sender, amount);
    }

    // ----------------------------------------------------------------------------------
    // Modifiers
    // ----------------------------------------------------------------------------------

    /// @notice Restrict a function to the trading window (before closeTime).
    /// @dev A modifier wraps the function body; `_;` is where the body runs. If the check
    ///      fails we revert and the body never executes.
    modifier whenOpen() {
        if (block.timestamp >= closeTime) revert PredictionMarket__TradingClosed();
        _;
    }

    // ----------------------------------------------------------------------------------
    // Stage 2: liquidity (first funding), pricing, and buy/sell (the CPMM core)
    // ----------------------------------------------------------------------------------

    /// @notice Seed the market with initial liquidity at a 50/50 price.
    /// @dev Stage 2 only supports the FIRST funding (empty pool). The `amount` collateral is
    ///      split into `amount` YES + `amount` NO, both kept as equal reserves (so price is
    ///      0.50 each), and the funder is minted `amount` LP shares. Stage 4 generalizes this
    ///      to additional providers on an already-funded (possibly unbalanced) pool.
    /// @param amount collateral to deposit as liquidity
    function addLiquidity(uint256 amount) external nonReentrant whenOpen {
        if (amount == 0) revert PredictionMarket__ZeroAmount();
        if (totalShares != 0) revert PredictionMarket__AlreadyFunded();

        // ---- Effects ----
        // Equal reserves ⇒ priceYes = priceNo = 0.50. Each reserve token is backed 1:1 by
        // the collateral we are about to pull in (so `amount` collateral backs `amount` sets).
        reserveYes = amount;
        reserveNo = amount;
        // Define the unit: 1 LP share == 1 unit of initial depth, so shares == amount here.
        totalShares = amount;
        sharesOf[msg.sender] = amount;

        // ---- Interaction ----
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        emit LiquidityAdded(msg.sender, amount, amount);
    }

    /// @notice Current YES price, scaled by WAD (e.g. 0.80 is returned as 8e17).
    /// @dev price(YES) = reserveNo / (reserveYes + reserveNo). The scarcer reserve (YES) maps
    ///      to the higher price. Multiply by WAD BEFORE dividing so we don't truncate to 0.
    function priceYes() external view returns (uint256) {
        if (totalShares == 0) revert PredictionMarket__PoolNotFunded();
        return reserveNo * WAD / (reserveYes + reserveNo);
    }

    /// @notice Current NO price, scaled by WAD. priceYes + priceNo == WAD (they sum to 1).
    function priceNo() external view returns (uint256) {
        if (totalShares == 0) revert PredictionMarket__PoolNotFunded();
        return reserveYes * WAD / (reserveYes + reserveNo);
    }

    /// @notice How many `outcome` tokens a buyer receives for `investmentAmount` collateral.
    /// @dev Constant-product math. Let x be the investment after fees. Buying `outcome` adds x
    ///      to the OTHER reserve and pays out from THIS reserve so that k = rThis*rOther holds:
    ///        sharesOut = (rThis + x) - (rThis*rOther)/(rOther + x)
    ///      We ceil-divide the subtracted term so sharesOut rounds DOWN (in the pool's favor).
    /// @param outcome Yes or No — the side being bought
    /// @param investmentAmount gross collateral the buyer will pay (fee is taken from this)
    /// @return sharesOut outcome tokens credited to the buyer
    function calcBuyAmount(Outcome outcome, uint256 investmentAmount) public view returns (uint256) {
        if (totalShares == 0) revert PredictionMarket__PoolNotFunded();
        (uint256 rThis, uint256 rOther) = _reserves(outcome);

        // Net investment after the trading fee. Integer division rounds the fee UP slightly
        // (x rounds down), which keeps value in the pool — the fee stays as bare collateral.
        uint256 x = investmentAmount * (FEE_DENOM - feeBps) / FEE_DENOM;

        // sharesOut = (rThis + x) - ceil( rThis*rOther / (rOther + x) )
        uint256 sharesOut = (rThis + x) - _ceilDiv(rThis * rOther, rOther + x);
        return sharesOut;
    }

    /// @notice How many `outcome` tokens a seller must return to receive `returnAmount` collateral.
    /// @dev Gnosis closed form (no sqrt). Gross the desired return up by the fee, require it to
    ///      be payable from the OTHER reserve, then:
    ///        sharesIn = R + (rThis*rOther)/(rOther - R) - rThis,   R = returnAmount grossed-up
    ///      Ceil-divide so sharesIn rounds UP (the seller pays at least enough — pool's favor).
    /// @param outcome Yes or No — the side being sold
    /// @param returnAmount net collateral the seller wants to receive
    /// @return sharesIn outcome tokens the seller must hand in
    function calcSellAmount(Outcome outcome, uint256 returnAmount) public view returns (uint256) {
        if (totalShares == 0) revert PredictionMarket__PoolNotFunded();
        (uint256 rThis, uint256 rOther) = _reserves(outcome);

        // Gross up: the pool's curve sees returnAmount/(1 - fee); the fee is retained on sell.
        uint256 R = _ceilDiv(returnAmount * FEE_DENOM, FEE_DENOM - feeBps);
        // The pool must be able to pull R out of the opposite reserve; else it can't pay.
        if (R >= rOther) revert PredictionMarket__ReturnTooHigh();

        uint256 sharesIn = R + _ceilDiv(rThis * rOther, rOther - R) - rThis;
        return sharesIn;
    }

    /// @notice Buy `outcome` tokens with collateral, reverting if you'd get fewer than `minSharesOut`.
    /// @param outcome Yes or No
    /// @param investmentAmount gross collateral to spend (includes the fee)
    /// @param minSharesOut slippage guard — minimum acceptable tokens out
    function buy(Outcome outcome, uint256 investmentAmount, uint256 minSharesOut)
        external
        nonReentrant
        whenOpen
    {
        if (investmentAmount == 0) revert PredictionMarket__ZeroAmount();
        if (outcome != Outcome.Yes && outcome != Outcome.No) revert PredictionMarket__InvalidOutcome();
        if (totalShares == 0) revert PredictionMarket__PoolNotFunded();

        uint256 sharesOut = calcBuyAmount(outcome, investmentAmount);
        if (sharesOut < minSharesOut) revert PredictionMarket__SlippageExceeded();

        // Net investment that actually enters the curve; the rest (the fee) stays as collateral.
        uint256 x = investmentAmount * (FEE_DENOM - feeBps) / FEE_DENOM;

        // ---- Effects: move along the curve ----
        // The bought side's reserve shrinks (we pay it out); the other side's reserve grows by x.
        if (outcome == Outcome.Yes) {
            reserveYes = reserveYes + x - sharesOut; // == k / (reserveNo + x)
            reserveNo = reserveNo + x;
            yesBalanceOf[msg.sender] += sharesOut;
        } else {
            reserveNo = reserveNo + x - sharesOut;
            reserveYes = reserveYes + x;
            noBalanceOf[msg.sender] += sharesOut;
        }

        // ---- Interaction: pull the FULL investment (fee included) ----
        collateral.safeTransferFrom(msg.sender, address(this), investmentAmount);
        emit Buy(msg.sender, outcome, investmentAmount, sharesOut);
    }

    /// @notice Sell `outcome` tokens for collateral, reverting if it would cost more than `maxSharesIn`.
    /// @param outcome Yes or No
    /// @param returnAmount net collateral you want to receive
    /// @param maxSharesIn slippage guard — maximum tokens you're willing to hand in
    function sell(Outcome outcome, uint256 returnAmount, uint256 maxSharesIn)
        external
        nonReentrant
        whenOpen
    {
        if (returnAmount == 0) revert PredictionMarket__ZeroAmount();
        if (outcome != Outcome.Yes && outcome != Outcome.No) revert PredictionMarket__InvalidOutcome();
        if (totalShares == 0) revert PredictionMarket__PoolNotFunded();

        uint256 sharesIn = calcSellAmount(outcome, returnAmount);
        if (sharesIn > maxSharesIn) revert PredictionMarket__SlippageExceeded();

        // Grossed-up amount the curve/merge sees; (R - returnAmount) is the retained fee.
        uint256 R = _ceilDiv(returnAmount * FEE_DENOM, FEE_DENOM - feeBps);

        // ---- Effects ----
        // The seller's tokens flow into the sold side's reserve; then the pool merges R complete
        // sets out of both reserves to source the collateral it pays.
        if (outcome == Outcome.Yes) {
            if (yesBalanceOf[msg.sender] < sharesIn) revert PredictionMarket__InsufficientYes();
            yesBalanceOf[msg.sender] -= sharesIn;
            reserveYes = reserveYes + sharesIn - R; // == k / (reserveNo - R)
            reserveNo = reserveNo - R;
        } else {
            if (noBalanceOf[msg.sender] < sharesIn) revert PredictionMarket__InsufficientNo();
            noBalanceOf[msg.sender] -= sharesIn;
            reserveNo = reserveNo + sharesIn - R;
            reserveYes = reserveYes - R;
        }

        // ---- Interaction: pay the NET return (fee stays in the contract) ----
        collateral.safeTransfer(msg.sender, returnAmount);
        emit Sell(msg.sender, outcome, returnAmount, sharesIn);
    }

    // ----------------------------------------------------------------------------------
    // Internal helpers
    // ----------------------------------------------------------------------------------

    /// @dev Returns (reserve of `outcome`, reserve of the opposite outcome). Lets buy/sell math
    ///      be written once in terms of (rThis, rOther) instead of duplicating YES/NO branches.
    function _reserves(Outcome outcome) internal view returns (uint256 rThis, uint256 rOther) {
        if (outcome == Outcome.Yes) return (reserveYes, reserveNo);
        if (outcome == Outcome.No) return (reserveNo, reserveYes);
        revert PredictionMarket__InvalidOutcome();
    }

    /// @dev Ceiling division: smallest integer >= a/b. Used to round trade math in the pool's
    ///      favor. Requires b > 0 (our callers guarantee it). a + b - 1 cannot overflow for
    ///      our bounded reserves; Stage 6 fuzzing bounds inputs to keep rThis*rOther in range.
    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }
}
