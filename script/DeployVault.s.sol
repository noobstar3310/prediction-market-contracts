// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vault} from "../src/Vault.sol";

/// @notice Deploys the Vault, wiring in the already-deployed TTT token on the devnet.
/// @dev Set TTT_ADDRESS to the devnet TTT token address, then:
///        forge script script/DeployVault.s.sol \
///          --rpc-url <DEVNET_RPC_URL> --broadcast --private-key <DEPLOYER_KEY>
///      Copy the printed Vault address wherever it's needed.
contract DeployVault is Script {
    function run() external returns (Vault vault) {
        address ttt = vm.envAddress("TTT_ADDRESS");

        console2.log("");
        console2.log("============ DEPLOY: Vault ============");
        console2.log("Broadcaster (deployer):", msg.sender);
        console2.log("TTT token             :", ttt);
        console2.log("---------------------------------------");

        vm.startBroadcast();
        vault = new Vault(IERC20(ttt));
        vm.stopBroadcast();

        console2.log("DONE. Vault deployed at:", address(vault));
        console2.log("=======================================");
    }
}
