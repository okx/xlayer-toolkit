// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {SP1Verifier} from "@sp1-contracts/src/v5.0.0/SP1VerifierPlonk.sol";

/// @title Deploy Real SP1 Verifier (Plonk v5.0.0)
/// @notice Deployment script for v5.0.0 Plonk verifier using constructor
contract DeployRealVerifierPlonk is Script {
    function run() public {
        vm.startBroadcast();
        
        // Deploy SP1VerifierPlonk using constructor
        SP1Verifier verifier = new SP1Verifier();
        
        console.log("===========================================");
        console.log("SP1VerifierPlonk v5.0.0 deployed");
        console.log("===========================================");
        console.log("SP1VerifierPlonk deployed at:", address(verifier));
        console.log("===========================================");
        
        vm.stopBroadcast();
    }
}
