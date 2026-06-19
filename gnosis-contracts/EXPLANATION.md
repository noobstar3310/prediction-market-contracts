# Gnosis Contracts — Detailed Walkthrough & Security Notes

> Purpose: explain the entire `gnosis-contracts/` folder as a reference for building
> `src/PredictionMarket.sol`, with a focus on **what to borrow, what to skip, and where
> the security lessons are** for a from-scratch mainnet (USDC / L2) deployment.

---

## Big picture: you have TWO different generations of Gnosis code

The folder is not one codebase — it's two separate Git repos representing two eras of
Gnosis prediction markets:

| Folder | What it is | Era / Solidity | Token model | Pricing |
|---|---|---|---|---|
| `pm-contracts/` | **Gnosis Prediction Markets v1** | 2017–18, `^0.5.0` | Each outcome = its own **ERC20** | **LMSR** (logarithmic market maker) |
| `conditional-tokens-contracts/` | **Conditional Tokens Framework (CTF)** — "Gnosis 2.0" | 2019, `^0.5.1` | All outcomes = **ERC1155** positions in one contract | **No built-in maker** (split/merge primitive only) |

The CTF is the more important one. It's the primitive that **Polymarket, Omen, and Azuro**
are built on, and it's the direct ancestor of your `split()`/`merge()`. The v1
`pm-contracts` is largely historical, but its LMSR maker and its Event/Oracle separation
are still worth studying.

### ⚠️ One thing to flag immediately

Your contract's header says the lineage is *"Gnosis FixedProductMarketMaker (buy/sell/fund
math) + ConditionalTokens (split/merge)."* That's the right mental model — **but
`FixedProductMarketMaker` (FPMM) is not in either of these folders.** FPMM lives in a third
repo (`conditional-tokens-market-makers`). So:

- The `split`/`merge` half of your design **can** be cross-checked against
  `ConditionalTokens.sol` here. ✅
- The `buy`/`sell`/`calcBuyAmount`/`calcSellAmount` half **cannot** — the only market maker
  in this folder is **LMSR**, which is a completely different (exponential, not
  constant-product) curve. If the goal is to verify your CPMM math against the audited
  source, you need to pull the FPMM repo separately.

---

# Part 1 — `conditional-tokens-contracts/` (the one that matters most)

The Solidity files that actually matter:
- `contracts/ConditionalTokens.sol` — the core logic
- `contracts/CTHelpers.sol` — ID-derivation library
- `contracts/ERC1155/*` — a vendored ERC1155 implementation
- `test/*.sol` — mocks (GnosisSafe, MockCoin, ERC1155Mock…), not for production
- `contracts/Migrations.sol` — Truffle deploy bookkeeping, ignore

## 1.1 `ConditionalTokens.sol` — the heart

This is one contract that manages *every* market ever created on it. It has four verbs.
Map them to your contract:

| CTF function | Your equivalent |
|---|---|
| `prepareCondition` | (no equivalent — you create one market = one deploy) |
| `splitPosition` | `split()` |
| `mergePositions` | `merge()` |
| `reportPayouts` | `resolve()` (not yet written) |
| `redeemPositions` | `redeem()` (not yet written) |

### `prepareCondition` (lines 65–73)

```solidity
function prepareCondition(address oracle, bytes32 questionId, uint outcomeSlotCount) external {
    require(outcomeSlotCount <= 256, "too many outcome slots");
    require(outcomeSlotCount > 1, "there should be more than one outcome slot");
    bytes32 conditionId = CTHelpers.getConditionId(oracle, questionId, outcomeSlotCount);
    require(payoutNumerators[conditionId].length == 0, "condition already prepared");
    payoutNumerators[conditionId] = new uint[](outcomeSlotCount);
    emit ConditionPreparation(...);
}
```

This is the "create a market" step. Because CTF is a *singleton* serving many markets, a
market isn't a deployed contract — it's a `conditionId` computed as:

```
conditionId = keccak256(oracle, questionId, outcomeSlotCount)
```

**Security lesson #1 (the big one): the oracle is baked into the ID.** `oracle` is part of
the hash. This means later, when someone reports a result, *they can only report for a
condition whose ID includes their own address*. There is no "who is allowed to resolve?"
access-control check anywhere — the identity check is structural, done by hashing. Your
contract takes the simpler, equally-valid route: a single `immutable resolver` checked with
`msg.sender == resolver`. Both solve the *same* problem (only the right party resolves) two
different ways.

`require(payoutNumerators[conditionId].length == 0)` prevents re-preparing — you can't reset
a market. Your equivalent guard is the constructor running exactly once.

### `splitPosition` (lines 105–163) — compare to your `split()`

The general CTF version handles N outcomes, nested conditions, and partial partitions, which
is why it's long. Strip all that away and the **collateral path** (lines 132–135) is
*exactly your `split`*:

```solidity
if (freeIndexSet == 0) {                       // splitting the FULL set
    if (parentCollectionId == bytes32(0)) {    // backed by raw collateral
        require(collateralToken.transferFrom(msg.sender, address(this), amount), "...");
    } ...
}
_batchMint(msg.sender, positionIds, amounts, "");   // mint one token per outcome
```

Translated to your binary case: pull `amount` collateral in, mint `amount` of each outcome
to the caller:

```solidity
yesBalanceOf[msg.sender] += amount;
noBalanceOf[msg.sender]  += amount;
collateral.safeTransferFrom(msg.sender, address(this), amount);
```

**The 1:1 backing invariant is identical**, and it's the foundation of solvency in both.
Every full set in existence is backed by exactly one unit of collateral locked in the
contract.

The loop at lines 123–130 is **bitmask accounting**:

```solidity
require(indexSet > 0 && indexSet < fullIndexSet, "got invalid index set");
require((indexSet & freeIndexSet) == indexSet, "partition not disjoint");
freeIndexSet ^= indexSet;
```

For a 3-outcome condition, `fullIndexSet = 0b111`. Each `indexSet` is a subset of outcomes
(e.g. `0b101` = "outcome A or C"). The `& / ^` dance guarantees the partition is *disjoint
and covers no slot twice* — the on-chain enforcement that you can't mint more value than you
put in. In binary this collapses to "YES and NO," so you don't need the machinery, but this
is *the* technique if you ever generalize to categorical (>2 outcome) markets.

### CEI / reentrancy — a key difference from your contract

`splitPosition` does `transferFrom` (interaction) and then `_batchMint` (which, in ERC1155,
calls `onERC1155Received` on the recipient — *another* external call). CTF has **no
`ReentrancyGuard`**. It's considered safe because:
1. All "balances" are ERC1155 internal ledger entries keyed by position ID, and
2. The mint happens *after* collateral is received, and re-entering `splitPosition` would
   just require *more* collateral each time.

Your contract is **stricter and safer here**: you use OpenZeppelin's `nonReentrant` on
`split`/`merge`/`buy`/`sell`, *and* you follow Checks-Effects-Interactions (ledger updated
before `safeTransfer`). That's the right call for a from-scratch mainnet deploy — keep it.
The lesson to internalize from CTF is **why** it's safe without a guard, so you understand
the property you're protecting.

### `reportPayouts` (lines 78–97) — the model for your `resolve()`

```solidity
function reportPayouts(bytes32 questionId, uint[] calldata payouts) external {
    ...
    bytes32 conditionId = CTHelpers.getConditionId(msg.sender, questionId, payouts.length);
    require(payoutNumerators[conditionId].length == outcomeSlotCount, "condition not prepared or found");
    require(payoutDenominator[conditionId] == 0, "payout denominator already set");  // resolve once
    uint den = 0;
    for (...) { den = den.add(num); payoutNumerators[conditionId][i] = num; }
    require(den > 0, "payout is all zeroes");
    payoutDenominator[conditionId] = den;
}
```

Two design ideas here are more powerful than a plain "winner" enum:

1. **Payouts are a *vector of numerators*, not a single winner.** A binary YES win is
   `[0, 1]`; a NO win is `[1, 0]`; **a tie/refund/invalid market is `[1, 1]`** (each side
   redeems half). Your current `Outcome { Unset, Yes, No }` design **has no way to express
   "invalid / refund everyone."** On a real mainnet market this matters a lot — questions get
   voided, oracles need an escape hatch. Strongly consider adding an `Invalid`/`split`
   resolution path so funds aren't stranded if the event is ambiguous. **This is the single
   most valuable idea to lift from this file.**

2. **`payoutDenominator == 0` is the "is it resolved?" flag** (line 84, and gating
   `redeemPositions` at line 219). Cheap and clean. Your equivalent is
   `winningOutcome != Unset`.

### `redeemPositions` (lines 218–255) — the model for your `redeem()`

```solidity
uint den = payoutDenominator[conditionId];
require(den > 0, "result for condition not received yet");      // must be resolved
...
uint payoutStake = balanceOf(msg.sender, positionId);
if (payoutStake > 0) {
    totalPayout = totalPayout.add(payoutStake.mul(payoutNumerator).div(den));
    _burn(msg.sender, positionId, payoutStake);                 // burn before pay
}
...
collateralToken.transfer(msg.sender, totalPayout);
```

The payout formula is:

```
payout = stake * (numerator_outcome / denominator)
```

For your binary winner-take-all market this simplifies to: *winning tokens redeem for 1
collateral each, losing tokens for 0.* When you write `redeem()`, mirror this structure
exactly: (1) require resolved, (2) read the caller's winning-token balance, (3) **burn it
from the ledger first**, (4) `safeTransfer` last. CEI again.

**Security lesson #2:** CTF burns the stake *before* transferring (lines 243 then 249). You
must do the same in `redeem`, or a reentrant token could let someone redeem twice.

### One thing CTF does that you correctly *improved*

CTF uses **raw** `collateralToken.transfer(...)` / `transferFrom(...)` wrapped in
`require(...)` (lines 135, 196, 249). That breaks on non-standard ERC20s like USDT that don't
return a bool. Since the real target is **USDC on an L2**, your choice of `SafeERC20`
(`safeTransfer`/`safeTransferFrom`) is strictly better — keep it. CTF predates SafeERC20
being standard.

### Shared assumption: no fee-on-transfer / rebasing tokens

CTF's 1:1 backing breaks under fee-on-transfer tokens exactly like yours does (if
`transferFrom` of 100 only delivers 99, you've minted 100 sets backed by 99). Your NatSpec
already documents this restriction. USDC is safe today, but USDC has an *unactivated* fee
switch in its contract — worth a one-line note that the design assumes the fee stays off.

## 1.2 `CTHelpers.sol` — the ID library (and that giant `sqrt`)

Three pure/view functions:

- `getConditionId` (line 10): just `keccak256(oracle, questionId, outcomeSlotCount)`.
- `getPositionId` (line 429): `keccak256(collateralToken, collectionId)` → the ERC1155 id.
- `getCollectionId` (line 392): the scary one.

That ~370-line assembly `sqrt` and the elliptic-curve math in `getCollectionId` exist for
**one reason**: CTF lets you nest conditions (a position can be "YES on market A *and* NO on
market B"). To combine collection IDs *commutatively and collision-resistantly*, Gnosis maps
IDs onto the **alt-bn128 elliptic curve** and uses point addition (the `staticcall` to
`address(6)` at line 415 is the EVM's `ECADD` precompile). The constant `P` (line 14) is the
bn128 field prime; `B = 3` is the curve's `b` parameter (`y^2 = x^3 + 3`).

**For your purposes: you do not need any of this, and you should not copy it.** It's only
relevant to *combinatorial/nested* markets. A single binary market never combines
collections. Copying it would add ~370 lines of attack surface for zero benefit.

## 1.3 `ERC1155/` — vendored token standard

`ERC1155.sol`, `IERC1155.sol`, `ERC1155TokenReceiver.sol`, `IERC1155TokenReceiver.sol`. This
is how CTF makes outcome positions transferable/tradeable: every position is a fungible
ERC1155 id. You deliberately chose an **internal mapping ledger**
(`yesBalanceOf`/`noBalanceOf`) instead — simpler, no transfer hooks, no callback reentrancy
surface. Reasonable simplification *for a closed market*, but the tradeoff: **your outcome
tokens are not transferable or composable.** Users can only buy/sell against your pool; they
can't send a YES position to a friend or use it elsewhere. If "tokens must be
ERC20/tradeable" is ever a product requirement, you'd be reinventing what CTF gave you for
free. Worth confirming a closed ledger is acceptable.

---

# Part 2 — `pm-contracts/` (Gnosis v1 — the older architecture)

Organized into four roles **separated into different contracts**: `Events/`,
`MarketMakers/`, `Markets/`, `Oracles/`, `Tokens/`. The whole architecture is a lesson in
**separation of concerns** — your single `PredictionMarket.sol` fuses all of these roles
into one contract. That's fine and often safer (less cross-contract trust), but seeing the
split clarifies the responsibilities.

## 2.1 `Tokens/OutcomeToken.sol` — outcomes as ERC20

```solidity
modifier isEventContract () { require(msg.sender == eventContract); _; }
function issue(address _for, uint amount) public isEventContract { _mint(_for, amount); }
function revoke(address _for, uint amount) public isEventContract { _burn(_for, amount); }
```

Each outcome is a standalone ERC20 that **only the Event contract can mint/burn**. This is
the v1 equivalent of your `yesBalanceOf[x] += amount`. The `isEventContract` modifier is the
trust anchor: minting authority is locked to one address. In your design, "only this
contract can change balances" is enforced trivially because the balances *are* internal
storage — nobody else can touch them. Same guarantee, less code.

## 2.2 `Events/Event.sol` — the split/merge layer of v1

```solidity
function buyAllOutcomes(uint count) public {
    require(collateralToken.transferFrom(msg.sender, address(this), count));
    for (...) outcomeTokens[i].issue(msg.sender, count);   // == your split()
}
function sellAllOutcomes(uint count) public {
    for (...) outcomeTokens[i].revoke(msg.sender, count);
    require(collateralToken.transfer(msg.sender, count));   // == your merge()
}
```

`buyAllOutcomes` / `sellAllOutcomes` **are** `split` / `merge` under different names — pull
collateral, mint a full set / burn a full set, return collateral. Identical 1:1 backing
invariant. `setOutcome()` (line 63) pulls the result from the Oracle, and the abstract
`redeemWinnings()` is the v1 redeem. Note these use raw `transfer`/`require` again (no
SafeERC20) and **no reentrancy guard** — same era-appropriate caveats as CTF.

## 2.3 `Oracles/Oracle.sol` + `CentralizedOracle.sol` — your resolver model

`Oracle.sol` is a 2-function interface: `isOutcomeSet()` and `getOutcome()`.
`CentralizedOracle.sol` matches **your trusted-multisig-resolver setup** most closely:

```solidity
modifier isOwner () { require(msg.sender == owner); _; }
function setOutcome(int _outcome) public isOwner {
    require(!isSet);          // resolve exactly once
    isSet = true;
    outcome = _outcome;
}
```

Three things to copy into your `resolve()`:
1. **`require(!isSet)`** — resolution is one-shot and irreversible. Your equivalent: require
   `winningOutcome == Unset` at the top of `resolve()`.
2. **`onlyOwner`-style gate** — yours is `msg.sender == resolver`. ✅
3. **`replaceOwner` (lines 56–64)** can only run *before* `isSet`. The resolver can be
   rotated until it has spoken, then frozen forever. Given your "centralized multisig
   resolver" model, consider a similar pre-resolution rotation path (multisig key rotation
   happens).

`int outcome` instead of an enum is a v1 quirk; your `Outcome` enum is cleaner. The other
oracle files (`Difficulty`, `Majority`, `SignedMessage`, `Ultimate`, `Futarchy`) are exotic
resolution mechanisms (Schelling-point, multisig-of-oracles, escalation games).
**`UltimateOracle` is worth a later look** if you ever want a dispute/challenge window on top
of your centralized resolver — it lets the community override a bad oracle call within a time
window. Not needed for v1, but it's the audited reference for "what if the resolver lies?"

## 2.4 `Markets/` and `MarketMakers/` — the LMSR pricing engine

This is the half that does **not** match your CPMM, so read it for contrast, not copying.

`Market.sol` / `MarketMaker.sol` are abstract interfaces. `StandardMarket.sol` is the
concrete market: `fund` / `close` / `buy` / `sell` / `shortSell` / `trade`, with `fee` out of
`FEE_RANGE = 1_000_000` (100%). Compare to your `feeBps` out of `FEE_DENOM = 10_000`. Same
idea, finer granularity (parts-per-million vs basis points).

Notable patterns:

- **`tradeImpl` (lines 188–237)** is the unified buy/sell engine: positive
  `outcomeTokenAmounts` = buy, negative = sell. It computes net cost via the maker, takes the
  fee, enforces `collateralLimit` (their slippage guard — same role as your
  `minSharesOut`/`maxSharesIn`), then mints/transfers. Your separate `buy`/`sell` functions
  are easier to read; their unified `trade` is more flexible. Both valid.
- **`Stages` enum + `atStage` modifier** (Market.sol lines 31–35, StandardMarket lines
  48–52): `MarketCreated → MarketFunded → MarketClosed`. This is your
  `Status { Open, Closed, Resolved }` and your `whenOpen` modifier. Same
  lifecycle-as-state-machine pattern. ✅

`LMSRMarketMaker.sol` — the **Logarithmic Market Scoring Rule**, a *completely different curve
from your constant-product*:

```
C(q)      = b * ln( sum_i exp(q_i / b) )
price_i   = exp(q_i / b) / sum_j exp(q_j / b)
```

where `q_i` is net tokens sold of outcome `i` and `b` is a liquidity parameter derived from
`funding`. The cost of any trade is `C(q_after) - C(q_before)` — exactly the
`costLevelAfter - costLevelBefore` at lines 50/84/121.

Why the file is so complex (the `sumExpOffset` / `EXP_LIMIT` / `Fixed192x64Math` gymnastics
at lines 174–205): **`exp` overflows fast.** `exp(133)` barely fits in 192 bits, so they
subtract an `offset` (the max quantity) inside the exponent to keep everything in range — a
numerical-stability trick (log-sum-exp), not business logic. The
`EstimationMode.UpperBound`/`LowerBound` (lines 38, 47) deliberately round cost *up* and
profit *down* — **rounding always favors the pool**, the LMSR analog of *your* ceil-divisions
in `calcBuyAmount`/`calcSellAmount`.

**Security lesson #3 — the deepest one:** the entire reason LMSR uses upper/lower-bound
estimation, and the reason your CPMM uses `_ceilDiv`, is the same: **every rounding error
must leave value in the pool, never extract it.** The classic from-scratch-AMM exploit is
"round in the user's favor by 1 wei, repeat in a loop, drain the pool." Your ceil-div
direction looks correct on inspection (you round `sharesOut` down and `sharesIn` up), but
**this is precisely the property you must prove with fuzzing/invariant tests before
mainnet** — pick the invariant "pool collateral ≥ outstanding obligations" and hammer it.

You will **not** copy LMSR (it needs a fixed-point `exp`/`log` library — `Fixed192x64Math` —
that isn't even in this folder, and CPMM is the modern choice for binary markets). Study it
only to absorb the rounding philosophy.

## 2.5 The `Factory` contracts + `Proxy`

`StandardMarketFactory`, `EventFactory`, `CentralizedOracleFactory`, etc., plus the
`Proxy`/`Proxied` base in many constructors (`StandardMarketProxy`, `OutcomeTokenProxy`).
This is Gnosis's **mastercopy + proxy clone** pattern: deploy the logic once, then cheaply
clone many markets pointing at it. The `// HACK: Lining up storage with StandardToken`
comment in `OutcomeToken.sol` (line 11) is a manual **storage-layout-alignment** between
proxy and implementation — a notorious footgun where a mismatch corrupts state.

**Relevance to you:** if you deploy *one market per question*, you may eventually want a
factory + minimal-proxy (EIP-1167) to cut deploy gas. This is the audited reference — **but**
proxy storage alignment is genuinely dangerous and a common audit finding. For a first
mainnet deploy, prefer the simpler non-proxy path you're already on, and add a factory only
once the single-contract version is audited.

---

# Summary: what to take, what to leave

**Take (directly applicable to your contract):**
1. **Payout-vector resolution** including the `[1,1]` *invalid/refund* case
   (`reportPayouts`) — your `Outcome` enum currently can't express a voided market. Highest
   value idea here.
2. **One-shot, irreversible resolution** with a resolver gate, plus optional
   **pre-resolution resolver rotation** (`CentralizedOracle`).
3. **Burn-before-pay ordering in `redeem`** (`redeemPositions`) — model your unwritten
   `redeem()` on CTF.
4. The **rounding-always-favors-the-pool** discipline (LMSR estimation modes + your
   ceil-divs) — and the obligation to *fuzz-prove* it before mainnet.

**Leave (out of scope / would add attack surface):**
1. The `CTHelpers` elliptic-curve `sqrt`/`getCollectionId` — only for nested conditions you
   don't have.
2. LMSR math — wrong curve for you; needs a fixed-point lib that isn't even in this folder.
3. The proxy/factory pattern — defer until after your first audit.

**Where you're already ahead of this code (keep it):**
- `SafeERC20` instead of raw `transfer`/`require` (matters for USDC/USDT-class tokens).
- `ReentrancyGuard` + strict CEI everywhere.
- Custom errors and an `Outcome.Unset` sentinel — cleaner than v1's `int outcome`.

**The one gap to close before trusting "it's like the audited Gnosis code":** your
**buy/sell CPMM math has no counterpart in this folder.** The audited reference for that is
`FixedProductMarketMaker` in the separate `conditional-tokens-market-makers` repo. That's
where a from-scratch mainnet market is most likely to have a subtle, fund-draining bug, and
it's the part these folders *don't* let you verify.
