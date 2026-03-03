// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BuilderCodes} from "../src/BuilderCodes.sol";

/// @notice Script for deploying the BuilderCodes contract
contract DeployBuilderCodes is Script {
    function run() external returns (address) {
        // local
        // address owner = 0x0BFc799dF7e440b7C88cC2454f12C58f8a29D986;
        // address initialRegistrar = 0x4175fad66ebB1240dff55e018830C61Dd646FCce;

        // development
        // address owner = 0x1D8958f7b9AE9FbB9d78C1e1aB18b44Fd54a0B7A;
        // address initialRegistrar = 0x6Bd08aCF2f8839eAa8a2443601F2DeED892cd389;

        // production
        address owner = 0xa12579F2DD32ea03035692cc5DBA1DCa5f614271;
        address initialRegistrar = address(0);

        string memory uriPrefix = "https://api-spindl.coinbase.com/flywheel/metadata/nft/";

        console.log("Initial registrar:", initialRegistrar);
        console.log("URI Prefix:", uriPrefix);

        vm.startBroadcast();

        // Deploy the implementation contract
        BuilderCodes implementation =
            new BuilderCodes{salt: 0x8ace9ca5472a45afce9af1f68f915cd3b719b3f543ee88ca8feea089b8bbf03c}();

        // Prepare initialization data
        bytes memory initData = abi.encodeCall(BuilderCodes.initialize, (owner, initialRegistrar, uriPrefix));
        console.logBytes(initData);

        // Deploy the proxy
        ERC1967Proxy proxy = new ERC1967Proxy{salt: 0x7ec07a7e6e24a84d9be1af2d4f3d486d6958fbf507a9ac4a21389f7899068bd7}(
            address(implementation), initData
        );

        console.log("BuilderCodes implementation deployed at:", address(implementation));
        console.log("BuilderCodes proxy deployed at:", address(proxy));

        assert(address(implementation) == 0x0000010080e4FE8932638049E7488BB4504BAFfb);
        assert(address(proxy) == 0x000000BC7E6457e610fe52Dcc0ca5b3ce59C8E80);

        vm.stopBroadcast();

        return address(proxy);
    }
}
