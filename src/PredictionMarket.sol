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
}
