// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Deploys a MockERC20 collateral + the MarketFactory, for local (anvil) play.
///         This is what the ominari-admin app talks to: it calls factory.createMarket(...),
///         which deploys a PredictionMarket and emits MarketCreated.
/// @dev Run against a local node (anvil account #0 key shown is the standard anvil default):
///        forge script script/DeployMarketFactory.s.sol \
///          --rpc-url http://localhost:8545 --broadcast \
///          --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///      Copy the two printed addresses into ominari-admin/.env.local
///      (NEXT_PUBLIC_FACTORY_ADDRESS, NEXT_PUBLIC_COLLATERAL_ADDRESS), then restart `npm run dev`.
contract DeployMarketFactory is Script {
    function run() external returns (MockERC20 collateral, MarketFactory factory) {
        console2.log("");
        console2.log("============ DEPLOY: MarketFactory ============");
        console2.log("Broadcaster (deployer):", msg.sender);
        console2.log("block.timestamp       :", block.timestamp);
        console2.log("-----------------------------------------------");

        // Collateral policy (the "one standard mUSDT" pattern): if COLLATERAL_ADDRESS is set we
        // REUSE that existing token, so every deploy shares a single collateral contract. Only when
        // it is unset do we deploy a fresh mock (first-time / local anvil). `vm.envOr` returns the
        // default (address(0)) when the var is missing, so this never reverts. Read it BEFORE the
        // broadcast — it's a cheat-code read, not an on-chain transaction.
        address existing = vm.envOr("COLLATERAL_ADDRESS", address(0));

        vm.startBroadcast();

        // 1. Collateral: reuse the standard token if given, else deploy a fresh mock + mint play money.
        if (existing == address(0)) {
            console2.log("[1/2] No COLLATERAL_ADDRESS set -> deploying fresh MockERC20 + minting 1,000,000e18...");
            collateral = new MockERC20("Mock USDT", "mUSDT");
            collateral.mint(msg.sender, 1_000_000e18);
        } else {
            console2.log("[1/2] Reusing existing collateral at:", existing);
            collateral = MockERC20(existing);
        }

        // 2. Deploy the factory. It is unprivileged and holds no funds; anyone can createMarket.
        console2.log("[2/2] Deploying MarketFactory...");
        factory = new MarketFactory();

        vm.stopBroadcast();

        console2.log("-----------------------------------------------");
        console2.log("DONE. Put these in ominari-admin/.env.local:");
        console2.log("  NEXT_PUBLIC_COLLATERAL_ADDRESS =", address(collateral));
        console2.log("  NEXT_PUBLIC_FACTORY_ADDRESS    =", address(factory));
        console2.log("  deployer mUSDT balance          :", collateral.balanceOf(msg.sender));
        console2.log("===============================================");
    }
}
