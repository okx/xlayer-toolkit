// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";

import {BuilderCodes, Initializable} from "../../../src/BuilderCodes.sol";

/// @notice Unit tests for BuilderCodes constructor
contract ConstructorTest is Test {
    /// @notice Test that constructor disables initializers on implementation contract
    ///
    /// @param owner Fuzzed owner address
    /// @param registrar Fuzzed registrar address
    /// @param uriPrefix Fuzzed URI prefix
    function test_constructor_success_disablesInitializers(address owner, address registrar, string memory uriPrefix)
        public
    {
        BuilderCodes implementation = new BuilderCodes();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(owner, registrar, uriPrefix);
    }
}
