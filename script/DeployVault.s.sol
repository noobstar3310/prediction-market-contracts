// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vault} from "../src/Vault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Deploys the ERC20 payout Vault (admin-controlled, batch distribution).
/// @dev Run against a node:
///        forge script script/DeployVault.s.sol \
///          --rpc-url <RPC_URL> --broadcast --private-key <DEPLOYER_KEY>
///      Env vars:
///        COLLATERAL_ADDRESS  reuse an existing ERC20 as the vault token (else deploy a fresh mUSDT)
///        VAULT_ADMIN         initial admin/owner address (else the deployer)
contract DeployVault is Script {
    function run() external returns (Vault vault, IERC20 token) {
        address existing = vm.envOr("COLLATERAL_ADDRESS", address(0));
        address admin = vm.envOr("VAULT_ADMIN", msg.sender);

        console2.log("");
        console2.log("============ DEPLOY: Vault (ERC20 payout) ============");
        console2.log("Broadcaster (deployer):", msg.sender);
        console2.log("admin/owner           :", admin);
        console2.log("-----------------------------------------------------");

        vm.startBroadcast();

        // Token policy mirrors the other deploy scripts: reuse the standard token if given,
        // otherwise deploy a fresh mock so local runs work out of the box.
        if (existing == address(0)) {
            console2.log("No COLLATERAL_ADDRESS set -> deploying fresh MockERC20 (mUSDT)...");
            MockERC20 mock = new MockERC20("Mock USDT", "mUSDT");
            token = IERC20(address(mock));
        } else {
            console2.log("Reusing existing token at:", existing);
            token = IERC20(existing);
        }

        vault = new Vault(token, admin);
        vm.stopBroadcast();

        console2.log("DONE. Deployed addresses:");
        console2.log("  Vault :", address(vault));
        console2.log("  Token :", address(token));
        console2.log("  Admin :", admin);
        console2.log("=====================================================");
    }
}
