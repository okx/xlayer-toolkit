// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AccessManager} from "../../src/fp/AccessManager.sol";
import {IDisputeGameFactory} from "interfaces/dispute/IDisputeGameFactory.sol";

contract DeployAccessManager is Script {
    function run() public {
        vm.startBroadcast();
        
        // Read from environment variable (automatically fetches from env, fails if not set)
        address factoryAddress = vm.envAddress("DISPUTE_GAME_FACTORY_ADDRESS");
        uint256 fallbackTimeout = 1209600; // 14 days in seconds
        
        // Deploy AccessManager
        AccessManager accessManager = new AccessManager(
            fallbackTimeout,
            IDisputeGameFactory(factoryAddress)
        );
        
        // Configure for permissionless mode (anyone can propose/challenge)
        accessManager.setProposer(address(0), true);
        accessManager.setChallenger(address(0), true);
        
        console.log("==============================================");
        console.log("AccessManager deployed at:", address(accessManager));
        console.log("Factory address:", factoryAddress);
        console.log("Fallback timeout (seconds):", fallbackTimeout);
        console.log("Mode: Permissionless");
        console.log("==============================================");
        
        vm.stopBroadcast();
    }
}
