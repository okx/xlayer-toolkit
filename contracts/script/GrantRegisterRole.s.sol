// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BuilderCodes} from "../src/BuilderCodes.sol";

/// @notice Script for granting a Builder Codes register role to an account
contract GrantRegisterRole is Script {
    // production
    // BuilderCodes public builderCodes = BuilderCodes(0x000000BC7E6457e610fe52Dcc0ca5b3ce59C8E80);

    // development
    BuilderCodes public builderCodes = BuilderCodes(0xf20b8A32C39f3C56bBD27fe8438090B5a03b6381);

    function run() external {
        vm.startBroadcast();

        bytes32 role = builderCodes.REGISTER_ROLE();
        address account = 0x6Bd08aCF2f8839eAa8a2443601F2DeED892cd389; // Spindl dev server wallet

        builderCodes.grantRole(role, account);

        assert(builderCodes.hasRole(role, account));

        console.log("Granted REGISTER_ROLE to", account);

        vm.stopBroadcast();
    }
}
