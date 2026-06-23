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

    /// @notice The ERC20 used as collateral / settlement currency (e.g. mock USDT).
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

    /// @notice Trading fees accumulated as bare collateral, claimable by LPs on removeLiquidity.
    /// @dev Invariant: collateral.balanceOf(this) == totalOutcomeSupply + collectedFees
    ///      (pre-resolution). This is the running total of fees not yet withdrawn; how that total
    ///      is split among LPs is decided by the feePoolWeight accumulator below.
    uint256 public collectedFees;

    /// @notice Cumulative fees credited per LP share, scaled by WAD (the "feePoolWeight" / Gnosis
    ///         MasterChef-style accumulator). Each trade adds `fee * WAD / totalShares` here.
    /// @dev An LP's lifetime fee entitlement is `sharesOf[lp] * accFeePerShare / WAD`; subtracting
    ///      their `feeDebt` (the entitlement already accounted at their last interaction) yields the
    ///      fees they may still claim. This makes a share earn ONLY fees that accrued while it was
    ///      live, which closes the just-in-time fee-theft vector (audit finding #1).
    uint256 public accFeePerShare;

    /// @notice Per-LP baseline subtracted from their gross entitlement so freshly-minted shares
    ///         carry no claim on fees that accrued before the deposit.
    mapping(address => uint256) public feeDebt;

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

    /// @notice Emitted when `provider` burns `shares` and withdraws `collateralOut` plus any
    ///         residual outcome tokens (`yesOut`/`noOut`).
    event LiquidityRemoved(
        address indexed provider, uint256 shares, uint256 collateralOut, uint256 yesOut, uint256 noOut
    );

    /// @notice Emitted on a buy: `buyer` spent `investmentAmount` collateral for `sharesOut`
    ///         tokens of `outcome`.
    event Buy(address indexed buyer, Outcome outcome, uint256 investmentAmount, uint256 sharesOut);

    /// @notice Emitted on a sell: `seller` returned `sharesIn` tokens of `outcome` for
    ///         `returnAmount` collateral.
    event Sell(address indexed seller, Outcome outcome, uint256 returnAmount, uint256 sharesIn);

    /// @notice Emitted once, when the resolver declares the winning `outcome`.
    event Resolved(Outcome outcome);

    /// @notice Emitted when `account` redeems `amount` winning `outcome` tokens for `amount`
    ///         collateral 1:1.
    event Redeemed(address indexed account, Outcome outcome, uint256 amount);

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
    /// @notice Caller tried to remove more LP shares than they own.
    error PredictionMarket__InsufficientShares();
    /// @notice Outcome argument must be Yes or No (not the Unset sentinel).
    error PredictionMarket__InvalidOutcome();
    /// @notice Trading is no longer allowed because the market has reached closeTime.
    error PredictionMarket__TradingClosed();
    /// @notice The trade's result was worse than the caller's slippage limit.
    error PredictionMarket__SlippageExceeded();
    /// @notice Requested collateral-out on a sell is too large for the pool to honor.
    error PredictionMarket__ReturnTooHigh();
    /// @notice Caller is not the trusted resolver.
    error PredictionMarket__NotResolver();
    /// @notice Market has not reached closeTime yet, so it cannot be resolved.
    error PredictionMarket__NotClosed();
    /// @notice Market has already been resolved; the winner is set once and is final.
    error PredictionMarket__AlreadyResolved();
    /// @notice Operation requires the market to be resolved, but it is still open/closed.
    error PredictionMarket__NotResolved();
    /// @notice Caller holds no winning tokens, so there is nothing to redeem.
    error PredictionMarket__NothingToRedeem();

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

    /// @notice Add liquidity to the market and receive LP shares.
    /// @dev First funding (empty pool) seeds a 50/50 price. Subsequent funding adds at the
    ///      CURRENT price (Gnosis FPMM addFunding): shares are minted against the larger
    ///      reserve, each reserve grows proportionally so the price is preserved, and the
    ///      surplus of the smaller (pricier) side is returned to the LP as outcome tokens.
    /// @param amount collateral to deposit as liquidity
    function addLiquidity(uint256 amount) external nonReentrant whenOpen {
        if (amount == 0) revert PredictionMarket__ZeroAmount();

        uint256 sharesMinted;
        if (totalShares == 0) {
            // ---- First funding: seed a balanced 50/50 pool ----
            // `amount` collateral backs `amount` of each reserve (a full set per unit).
            reserveYes = amount;
            reserveNo = amount;
            sharesMinted = amount; // unit definition: 1 share == 1 unit of initial depth
        } else {
            // ---- Subsequent funding: add at the current price, preserving it ----
            // poolWeight is the LARGER reserve (the cheaper outcome). It is the binding
            // constraint on how much real depth this deposit adds.
            uint256 poolWeight = _max(reserveYes, reserveNo);

            // Shares scale with how much we grow that binding reserve. Round DOWN (pool's favor).
            sharesMinted = amount * totalShares / poolWeight;

            // Keep each side proportional to current reserves (ratio, hence price, unchanged).
            uint256 keepYes = amount * reserveYes / poolWeight;
            uint256 keepNo = amount * reserveNo / poolWeight;
            reserveYes += keepYes;
            reserveNo += keepNo;

            // The deposit minted `amount` of each outcome; whatever the pool didn't keep on
            // the smaller (pricier) side is surplus returned to the LP as an outcome position.
            yesBalanceOf[msg.sender] += amount - keepYes;
            noBalanceOf[msg.sender] += amount - keepNo;
        }

        totalShares += sharesMinted;
        sharesOf[msg.sender] += sharesMinted;
        // Credit the new shares' fee baseline so they cannot claim fees that accrued earlier.
        feeDebt[msg.sender] += sharesMinted * accFeePerShare / WAD;

        // ---- Interaction ----
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        emit LiquidityAdded(msg.sender, amount, sharesMinted);
    }

    /// @notice Burn LP shares to withdraw a proportional slice of the pool.
    /// @dev Returns proportional reserves (as outcome tokens) + proportional accrued fees.
    ///      Complete sets within the withdrawn reserves are merged straight to collateral; any
    ///      one-sided remainder stays as the LP's residual outcome position (directional risk).
    ///      Allowed in any phase, so an LP can exit before or after resolution.
    /// @param sharesToBurn number of LP shares to redeem
    function removeLiquidity(uint256 sharesToBurn) external nonReentrant {
        if (sharesToBurn == 0) revert PredictionMarket__ZeroAmount();
        if (sharesToBurn > sharesOf[msg.sender]) revert PredictionMarket__InsufficientShares();

        // This LP's proportional slice of each pool component. Round DOWN (pool's favor).
        uint256 sendYes = reserveYes * sharesToBurn / totalShares;
        uint256 sendNo = reserveNo * sharesToBurn / totalShares;
        // Fees the caller has earned = (gross entitlement of all their shares) - (their fee debt).
        // This harvests ALL of the caller's accrued fees, independent of how many shares they burn,
        // and is exactly 0 for shares that were minted after the last fee accrued (the JIT fix).
        uint256 feeShare = sharesOf[msg.sender] * accFeePerShare / WAD - feeDebt[msg.sender];

        // Complete sets among the withdrawn reserves merge 1:1 back into collateral.
        uint256 mergeable = _min(sendYes, sendNo);

        // ---- Effects ----
        reserveYes -= sendYes;
        reserveNo -= sendNo;
        collectedFees -= feeShare;
        sharesOf[msg.sender] -= sharesToBurn;
        totalShares -= sharesToBurn;
        // We just paid out all pending fees, so reset the debt to the remaining shares' entitlement.
        feeDebt[msg.sender] = sharesOf[msg.sender] * accFeePerShare / WAD;

        // Leftover (one-sided) outcome tokens become the LP's residual position.
        uint256 yesOut = sendYes - mergeable;
        uint256 noOut = sendNo - mergeable;
        yesBalanceOf[msg.sender] += yesOut;
        noBalanceOf[msg.sender] += noOut;

        // Collateral paid = merged complete sets + the LP's share of fees.
        uint256 collateralOut = mergeable + feeShare;

        // ---- Interaction ----
        collateral.safeTransfer(msg.sender, collateralOut);
        emit LiquidityRemoved(msg.sender, sharesToBurn, collateralOut, yesOut, noOut);
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
        uint256 fee = investmentAmount - x;
        collectedFees += fee; // retain the fee for LPs
        // Distribute this fee across the LP shares that exist right now (totalShares > 0 here).
        accFeePerShare += fee * WAD / totalShares;

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
        uint256 fee = R - returnAmount;
        collectedFees += fee; // retain the fee for LPs
        // Distribute this fee across the LP shares that exist right now (totalShares > 0 here).
        accFeePerShare += fee * WAD / totalShares;

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
    // Stage 5: resolution + redemption (settling the market)
    // ----------------------------------------------------------------------------------

    /// @notice Declare the winning outcome. Callable ONCE, only by the resolver, only after
    ///         closeTime. After this, trading is already blocked (whenOpen) and redemption opens.
    /// @dev Mirrors the Gnosis CentralizedOracle "owner sets the answer once" discipline. The
    ///      resolver is a trusted multisig+timelock in production. PRODUCTION HARDENING (flagged,
    ///      not built yet): a finalization/dispute delay between resolve() and the first redeem()
    ///      so a wrong answer can be challenged before money moves.
    ///
    ///      No `nonReentrant` here on purpose: this function makes NO external call (no token
    ///      transfer), so there is no callback an attacker could reenter through. The guard would
    ///      only burn gas. (redeem(), which DOES move collateral, keeps the guard.)
    /// @param outcome the winning side — must be Yes or No, never the Unset sentinel
    function resolve(Outcome outcome) external {
        // --- Access control: only the trusted resolver may settle the market. ---
        if (msg.sender != resolver) revert PredictionMarket__NotResolver();

        // --- Timing: cannot settle a question whose trading window is still open. We resolve
        //     strictly AT or AFTER closeTime. (whenOpen blocks trading at `>= closeTime`, so the
        //     two windows meet exactly at closeTime with no gap and no overlap.) ---
        if (block.timestamp < closeTime) revert PredictionMarket__NotClosed();

        // --- Idempotency: the winner is final. `Unset` is our "not yet resolved" sentinel, so
        //     anything other than Unset means we've already resolved once. ---
        if (winningOutcome != Outcome.Unset) revert PredictionMarket__AlreadyResolved();

        // --- Validity: the answer must be a real outcome. Allowing Unset would "resolve" the
        //     market while leaving it logically unresolved — a trap. ---
        if (outcome != Outcome.Yes && outcome != Outcome.No) revert PredictionMarket__InvalidOutcome();

        // --- Effect: record the winner. From now on winningOutcome != Unset gates redeem(). ---
        winningOutcome = outcome;
        emit Resolved(outcome);
    }

    /// @notice After resolution, burn your WINNING outcome tokens for an equal amount of
    ///         collateral (1:1). Losing tokens are worth nothing and are simply ignored.
    /// @dev Why 1:1 is always solvent: every outcome token in existence was minted as part of a
    ///      full set (split / buy / sell / liquidity all keep totalYES == totalNO == S), and the
    ///      contract holds S + collectedFees collateral. Only the winning side (exactly S tokens)
    ///      can ever be redeemed, and S <= the collateral on hand — so the pool can always pay
    ///      every winner in full, with the fee buffer left over for LPs.
    function redeem() external nonReentrant {
        // --- Gate: redemption only exists after the resolver has picked a winner. ---
        if (winningOutcome == Outcome.Unset) revert PredictionMarket__NotResolved();

        // --- Read the caller's balance on the WINNING side and zero it (Effects before the
        //     transfer = CEI). We pay out exactly what we burn, so backing stays exact. ---
        uint256 amount;
        if (winningOutcome == Outcome.Yes) {
            amount = yesBalanceOf[msg.sender];
            if (amount == 0) revert PredictionMarket__NothingToRedeem();
            yesBalanceOf[msg.sender] = 0;
        } else {
            amount = noBalanceOf[msg.sender];
            if (amount == 0) revert PredictionMarket__NothingToRedeem();
            noBalanceOf[msg.sender] = 0;
        }

        // Note: we deliberately leave the caller's LOSING balance untouched. It is unbacked and
        // worth 0, so it can never be redeemed; clearing it would only waste gas.

        // --- Interaction: release the collateral last. ---
        collateral.safeTransfer(msg.sender, amount);
        emit Redeemed(msg.sender, winningOutcome, amount);
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

    /// @dev Larger of two values.
    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    /// @dev Smaller of two values.
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a <= b ? a : b;
    }
}
