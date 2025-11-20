// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/Script.sol";

/// @title Deploy Real SP1 Verifier (Plonk v5.0.0)
/// @notice Deployment script for v5.0.0 Plonk verifier
contract DeployRealVerifierPlonk is Script {
    function run() external {
        vm.startBroadcast();

        // Deploy using the compiled bytecode from sp1-contracts
        // Path: lib/sp1-contracts/contracts/src/v5.0.0/SP1VerifierPlonk.sol
        address verifier = deployCode(
            "lib/sp1-contracts/contracts/src/v5.0.0/SP1VerifierPlonk.sol:SP1VerifierPlonk"
        );
        
        console.log("===========================================");
        console.log("SP1VerifierPlonk v5.0.0 deployed");
        console.log("===========================================");
        console.log("SP1VerifierPlonk deployed at:", verifier);
        console.log("===========================================");

        vm.stopBroadcast();
    }
}
