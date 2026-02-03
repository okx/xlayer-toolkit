// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../BatchInbox.sol";
import "../OutputOracle.sol";
import "../PreimageOracle.sol";
import "../MIPS.sol";
import "../DisputeGameFactory.sol";
import "../interfaces/IPreimageOracle.sol";

contract DeployScript is Script {
    // Default addresses from Anvil
    address constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant BATCHER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant PROPOSER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant CHALLENGER = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;

    // Challenge window: 5 minutes for testing (fast mode)
    uint256 constant CHALLENGE_WINDOW = 5 minutes;

    function run() external {
        uint256 deployerPrivateKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );

        address batcher = vm.envOr("BATCHER_ADDRESS", BATCHER);
        address proposer = vm.envOr("PROPOSER_ADDRESS", PROPOSER);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy BatchInbox
        BatchInbox batchInbox = new BatchInbox(batcher);
        console.log("BatchInbox deployed at:", address(batchInbox));

        // 2. Deploy PreimageOracle
        PreimageOracle preimageOracle = new PreimageOracle();
        console.log("PreimageOracle deployed at:", address(preimageOracle));

        // 3. Deploy MIPS (Cannon VM)
        MIPS mips = new MIPS(IPreimageOracle(address(preimageOracle)));
        console.log("MIPS deployed at:", address(mips));

        // 4. Deploy OutputOracle (initially without factory)
        OutputOracle outputOracle = new OutputOracle(
            proposer,
            address(0), // Will be set to factory later
            CHALLENGE_WINDOW
        );
        console.log("OutputOracle deployed at:", address(outputOracle));

        // 5. Deploy DisputeGameFactory
        DisputeGameFactory disputeGameFactory = new DisputeGameFactory(
            address(outputOracle),
            address(mips)
        );
        console.log("DisputeGameFactory deployed at:", address(disputeGameFactory));

        // 6. Update OutputOracle to reference DisputeGameFactory
        outputOracle.setDisputeGameFactory(address(disputeGameFactory));
        console.log("OutputOracle updated with DisputeGameFactory");

        vm.stopBroadcast();

        // Log deployment summary
        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("BatchInbox:", address(batchInbox));
        console.log("PreimageOracle:", address(preimageOracle));
        console.log("MIPS:", address(mips));
        console.log("OutputOracle:", address(outputOracle));
        console.log("DisputeGameFactory:", address(disputeGameFactory));
        console.log("");
        console.log("=== Roles ===");
        console.log("Batcher:", batcher);
        console.log("Proposer:", proposer);
        console.log("Challenger:", CHALLENGER);
        console.log("Challenge Window:", CHALLENGE_WINDOW, "seconds");
    }
}
