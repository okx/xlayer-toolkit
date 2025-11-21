// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/Script.sol";

/// @title Deploy Real SP1 Verifier (Plonk v5.0.0)
/// @notice Deployment script for v5.0.0 Plonk verifier using forge create
contract DeployRealVerifierPlonk is Script {
    function run() external returns (address) {
        vm.startBroadcast();

        // Deploy using deployCode which reads from compilation artifacts
        address verifier = deployCode("SP1VerifierPlonk.sol:SP1VerifierPlonk");
        
        console.log("===========================================");
        console.log("SP1VerifierPlonk v5.0.0 deployed");
        console.log("===========================================");
        console.log("SP1VerifierPlonk deployed at:", verifier);
        console.log("===========================================");

        vm.stopBroadcast();
        return verifier;
    }
}
