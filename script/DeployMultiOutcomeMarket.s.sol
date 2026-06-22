// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MultiOutcomeMarket} from "../src/MultiOutcomeMarket.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Deploys a MockERC20 collateral + a MultiOutcomeMarket, for local (anvil) play.
/// @dev Run against a local node:
///        anvil                                  # terminal 1
///        forge script script/DeployMultiOutcomeMarket.s.sol \
///          --rpc-url http://localhost:8545 --broadcast --private-key <anvil_key>
///
///      The number of outcome slots is configurable WITHOUT editing this file — set the
///      OUTCOME_SLOTS env var (defaults to 3 = a categorical market):
///        OUTCOME_SLOTS=2 forge script script/DeployMultiOutcomeMarket.s.sol ...   # binary/scalar
///        OUTCOME_SLOTS=4 forge script script/DeployMultiOutcomeMarket.s.sol ...   # 4-way categorical
///
///      The console2.log lines print the deployed addresses so you can poke them with `cast`.
contract DeployMultiOutcomeMarket is Script {
    function run() external returns (MockERC20 collateral, MultiOutcomeMarket market) {
        uint256 closeTime = block.timestamp + 7 days;

        // Read the desired outcome count from the environment; fall back to 3 (categorical).
        // `vm.envOr` returns the default when the env var isn't set, so this never reverts.
        uint256 outcomeSlots = vm.envOr("OUTCOME_SLOTS", uint256(3));

        // Collateral policy (the "one standard mUSD" pattern): if COLLATERAL_ADDRESS is set we REUSE
        // that existing token so every deploy shares a single collateral contract; only when unset do
        // we deploy a fresh mock. Read before the broadcast — it's a cheat-code read, not a tx.
        address existing = vm.envOr("COLLATERAL_ADDRESS", address(0));

        console2.log("");
        console2.log("=========== DEPLOY: MultiOutcomeMarket ===========");
        console2.log("Broadcaster (deployer):", msg.sender);
        console2.log("block.timestamp       :", block.timestamp);
        console2.log("planned closeTime     :", closeTime);
        console2.log("outcomeSlotCount      :", outcomeSlots);
        console2.log("--------------------------------------------------");

        // vm.startBroadcast tells Foundry: every call until stopBroadcast is a REAL transaction
        // signed by the broadcaster (the --private-key), not a simulated test call.
        vm.startBroadcast();

        // 1. Collateral: reuse the standard token if given, else deploy a fresh mock + mint play money.
        if (existing == address(0)) {
            console2.log("[1/4] No COLLATERAL_ADDRESS set -> deploying fresh MockERC20 + minting 1,000,000e18...");
            collateral = new MockERC20("Mock USD", "mUSD");
            collateral.mint(msg.sender, 1_000_000e18);
        } else {
            console2.log("[1/4] Reusing existing collateral at:", existing);
            collateral = MockERC20(existing);
        }

        // 2. Deploy the market: deployer is the resolver, closes in 7 days, 2% fee, N slots.
        console2.log("[2/4] Deploying MultiOutcomeMarket (resolver=deployer, fee=200bps)...");
        market = new MultiOutcomeMarket(collateral, msg.sender, closeTime, 200, outcomeSlots);

        // 3. Pre-approve the market so you can split/addLiquidity/buy without a separate approve tx.
        console2.log("[3/4] Approving market to spend deployer's collateral (max)...");
        collateral.approve(address(market), type(uint256).max);

        // 4. Seed the pool so it's immediately tradeable (sets all outcomes to equal odds).
        console2.log("[4/4] Seeding pool with 10,000e18 of liquidity (uniform starting odds)...");
        market.addLiquidity(10_000e18);

        vm.stopBroadcast();

        // Final summary — copy these addresses for your `cast` commands.
        console2.log("--------------------------------------------------");
        console2.log("DONE. Deployed addresses:");
        console2.log("  Collateral (mUSD)   :", address(collateral));
        console2.log("  MultiOutcomeMarket  :", address(market));
        console2.log("  Deployer/resolver   :", msg.sender);
        console2.log("State checks:");
        console2.log("  deployer mUSD balance:", collateral.balanceOf(msg.sender));
        console2.log("  market feeBps        :", market.feeBps());
        console2.log("  market closeTime     :", market.closeTime());
        console2.log("  market outcomeSlots  :", market.outcomeSlotCount());
        console2.log("  market totalShares   :", market.totalShares());
        console2.log("  pool funded?         : yes (seeded with 10,000e18)");
        console2.log("==================================================");
    }
}
