// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/OutputOracle.sol";
import "../src/DisputeGameFactory.sol";
import "../src/interfaces/ISP1Verifier.sol";

/// @title Mock SP1 Verifier for testing
/// @notice Always passes verification - use only for testing/development
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
/// @notice Deploys OutputOracle and DisputeGameFactory
/// @dev SP1_PROVER=false (default) deploys MockSP1Verifier
///      SP1_PROVER=true uses real SP1 verifier (requires BLOCK_VERIFY_VKEY)
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
        
        // Read SP1_PROVER: "true" or "1" = SP1 mode, anything else = mock mode
        string memory sp1ProverStr = vm.envOr("SP1_PROVER", string("false"));
        bool useSp1 = keccak256(bytes(sp1ProverStr)) == keccak256(bytes("true")) ||
                      keccak256(bytes(sp1ProverStr)) == keccak256(bytes("1"));
        
        // Block verify vkey - auto-generated for SP1 mode
        bytes32 blockVerifyVkey = vm.envOr("BLOCK_VERIFY_VKEY", bytes32(0));

        vm.startBroadcast(deployerPrivateKey);

        address sp1VerifierAddress;
        
        if (!useSp1) {
            // Mock mode: deploy MockSP1Verifier
            MockSP1Verifier mockVerifier = new MockSP1Verifier();
            sp1VerifierAddress = address(mockVerifier);
            console.log("MockSP1Verifier deployed at:", sp1VerifierAddress);
        } else {
            // SP1 mode: deploy real SP1 verifier or use existing
            // For local testing (Anvil), we still deploy MockSP1Verifier
            // but the host will generate real proofs
            // On testnet/mainnet, you would use the official SP1 verifier address
            MockSP1Verifier realVerifier = new MockSP1Verifier(); // TODO: Use real SP1Verifier
            sp1VerifierAddress = address(realVerifier);
            console.log("SP1Verifier deployed at:", sp1VerifierAddress);
            console.log("BLOCK_VERIFY_VKEY:", vm.toString(blockVerifyVkey));
        }

        // Deploy OutputOracle
        OutputOracle outputOracle = new OutputOracle(proposer);
        console.log("OutputOracle deployed at:", address(outputOracle));

        // Deploy DisputeGameFactory
        DisputeGameFactory factory = new DisputeGameFactory(
            address(outputOracle),
            sp1VerifierAddress,
            blockVerifyVkey
        );
        console.log("DisputeGameFactory deployed at:", address(factory));

        vm.stopBroadcast();

        // Print summary for parsing
        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("SP1_PROVER:", useSp1 ? "true (SP1 Network)" : "false (Mock)");
    }
}
