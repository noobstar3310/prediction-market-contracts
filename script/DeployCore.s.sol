// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {Vault} from "../src/Vault.sol";

/// @notice One-shot deploy of the core stack — mUSDT collateral, MarketFactory, and the payout
///         Vault — all sharing a SINGLE mUSDT, with the deployer as the Vault admin/owner.
///         (MultiOutcomeMarket is intentionally left out; deploy it later if needed.)
/// @dev Deploy with a keystore account (prompts for the keystore password):
///        forge script script/DeployCore.s.sol:DeployCore \
///          --rpc-url https://rpc.teiza-devnet.gateway.fm \
///          --account 0xteiza-dev --sender <DEPLOYER_ADDRESS> \
///          --broadcast
///      Optional env vars:
///        COLLATERAL_ADDRESS  reuse an existing mUSDT instead of deploying a fresh one
///        VAULT_ADMIN         override the Vault admin (defaults to the deployer/--sender)
contract DeployCore is Script {
    function run() external returns (MockERC20 collateral, MarketFactory factory, Vault vault) {
        // Read config BEFORE broadcasting (these are cheat-code reads, not on-chain txs).
        address existing = vm.envOr("COLLATERAL_ADDRESS", address(0));
        address admin = vm.envOr("VAULT_ADMIN", msg.sender);

        console2.log("");
        console2.log("============ DEPLOY: core stack ============");
        console2.log("Broadcaster (deployer):", msg.sender);
        console2.log("Vault admin/owner     :", admin);
        console2.log("-------------------------------------------");

        vm.startBroadcast();

        // 1. mUSDT: reuse the standard token if COLLATERAL_ADDRESS is set, else deploy a fresh mock
        //    and mint the deployer some play money.
        if (existing == address(0)) {
            console2.log("[1/3] Deploying fresh MockERC20 (mUSDT) + minting 1,000,000e18 to deployer...");
            collateral = new MockERC20("Mock USDT", "mUSDT");
            collateral.mint(msg.sender, 1_000_000e18);
        } else {
            console2.log("[1/3] Reusing existing mUSDT at:", existing);
            collateral = MockERC20(existing);
        }

        // 2. MarketFactory: unprivileged registry that deploys binary PredictionMarkets on demand.
        console2.log("[2/3] Deploying MarketFactory...");
        factory = new MarketFactory();

        // 3. Vault: ERC20 payout vault holding mUSDT; admin = deployer (or VAULT_ADMIN override).
        console2.log("[3/3] Deploying Vault (token = mUSDT, admin set above)...");
        vault = new Vault(IERC20(address(collateral)), admin);

        vm.stopBroadcast();

        console2.log("-------------------------------------------");
        console2.log("DONE. Deployed addresses:");
        console2.log("  mUSDT (collateral) :", address(collateral));
        console2.log("  MarketFactory      :", address(factory));
        console2.log("  Vault              :", address(vault));
        console2.log("  Vault admin/owner  :", admin);
        console2.log("");
        console2.log("ominari-admin/.env.local:");
        console2.log("  NEXT_PUBLIC_COLLATERAL_ADDRESS =", address(collateral));
        console2.log("  NEXT_PUBLIC_FACTORY_ADDRESS    =", address(factory));
        console2.log("  NEXT_PUBLIC_VAULT_ADDRESS      =", address(vault));
        console2.log("===========================================");
    }
}
