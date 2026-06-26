// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Vault} from "../src/Vault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Deploys a MockERC20 TTT token (or reuses an existing one) + a Vault, for local/devnet play.
/// @dev Run against a node:
///        forge script script/DeployVault.s.sol \
///          --rpc-url <RPC_URL> --broadcast --private-key <DEPLOYER_KEY>
///
///      Token policy (same "reuse the standard token" pattern as the market deploys): if TTT_ADDRESS
///      is set we REUSE that existing token; only when unset do we deploy a fresh mock TTT + mint
///      play money. `vm.envOr` returns the default when the var is missing, so this never reverts.
contract DeployVault is Script {
    function run() external returns (MockERC20 token, Vault vault) {
        address existing = vm.envOr("TTT_ADDRESS", address(0));

        console2.log("");
        console2.log("============ DEPLOY: Vault ============");
        console2.log("Broadcaster (deployer):", msg.sender);
        console2.log("block.timestamp       :", block.timestamp);
        console2.log("---------------------------------------");

        vm.startBroadcast();

        // 1. Token: reuse the standard TTT if given, else deploy a fresh mock + mint play money.
        if (existing == address(0)) {
            console2.log("[1/2] No TTT_ADDRESS set -> deploying fresh MockERC20 TTT + minting 1,000,000e18...");
            token = new MockERC20("Test Token", "TTT");
            token.mint(msg.sender, 1_000_000e18);
        } else {
            console2.log("[1/2] Reusing existing TTT at:", existing);
            token = MockERC20(existing);
        }

        // 2. Deploy the vault, wiring in the TTT token. MockERC20 is an ERC20, so it satisfies IERC20.
        console2.log("[2/2] Deploying Vault...");
        vault = new Vault(token);

        vm.stopBroadcast();

        console2.log("---------------------------------------");
        console2.log("DONE. Deployed addresses:");
        console2.log("  TTT token :", address(token));
        console2.log("  Vault     :", address(vault));
        console2.log("  deployer TTT balance:", token.balanceOf(msg.sender));
        console2.log("=======================================");
    }
}
