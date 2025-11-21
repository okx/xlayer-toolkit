// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {SP1MockVerifier} from "@sp1-contracts/src/SP1MockVerifier.sol";

contract DeploySP1MockVerifier is Script {
    function run() public {
        vm.startBroadcast();
        
        SP1MockVerifier verifier = new SP1MockVerifier();
        console.log("SP1MockVerifier deployed at:", address(verifier));
        
        vm.stopBroadcast();
    }
}
