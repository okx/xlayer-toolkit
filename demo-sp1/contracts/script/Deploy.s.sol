// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/OutputOracle.sol";
import "../src/DisputeGameFactory.sol";
import "../src/interfaces/ISP1Verifier.sol";

/// @title Mock SP1 Verifier for testing
contract MockSP1Verifier is ISP1Verifier {
    function verifyProof(
        bytes32,
        bytes memory,
        bytes memory
    ) external pure override {
        // Always pass in mock mode
    }
}

/// @title Deploy script for ZK Bisection contracts
contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address proposer = vm.envOr(
            "PROPOSER_ADDRESS",
            address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8)
        );

        vm.startBroadcast(deployerPrivateKey);

        // Deploy mock SP1 verifier
        MockSP1Verifier sp1Verifier = new MockSP1Verifier();
        console.log("SP1Verifier deployed at:", address(sp1Verifier));

        // Deploy OutputOracle
        OutputOracle outputOracle = new OutputOracle(proposer);
        console.log("OutputOracle deployed at:", address(outputOracle));

        // Deploy DisputeGameFactory
        // Use a dummy vkey for now
        bytes32 blockVerifyVkey = bytes32(0);
        DisputeGameFactory factory = new DisputeGameFactory(
            address(outputOracle),
            address(sp1Verifier),
            blockVerifyVkey
        );
        console.log("DisputeGameFactory deployed at:", address(factory));

        vm.stopBroadcast();

        // Print summary for parsing
        console.log("");
        console.log("=== Deployment Complete ===");
    }
}
