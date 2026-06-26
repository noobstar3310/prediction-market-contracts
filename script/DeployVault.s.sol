// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Vault} from "../src/Vault.sol";

/// @notice Deploys the native-token Vault (open shared ETH pool).
/// @dev Run against a node:
///        forge script script/DeployVault.s.sol \
///          --rpc-url <RPC_URL> --broadcast --private-key <DEPLOYER_KEY>
contract DeployVault is Script {
    function run() external returns (Vault vault) {
        console2.log("");
        console2.log("============ DEPLOY: Vault ============");
        console2.log("Broadcaster (deployer):", msg.sender);
        console2.log("block.timestamp       :", block.timestamp);
        console2.log("---------------------------------------");

        vm.startBroadcast();
        vault = new Vault();
        vm.stopBroadcast();

        console2.log("DONE. Vault:", address(vault));
        console2.log("=======================================");
    }
}
