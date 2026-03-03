// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BuilderCodes} from "../../../src/BuilderCodes.sol";
import {BuilderCodesTest} from "../../lib/BuilderCodesTest.sol";

/// @notice Unit tests for BuilderCodes.contractURI
contract ContractURITest is BuilderCodesTest {
    /// @notice Test that contractURI returns correct URI when base URI is set
    function test_contractURI_success_returnsCorrectURIWithBaseURI() public view {
        // The builderCodes contract is already initialized with URI_PREFIX
        string memory contractURI = builderCodes.contractURI();
        string memory expected = string.concat(URI_PREFIX, "contractURI.json");
        assertEq(contractURI, expected);
    }

    /// @notice Test that contractURI returns empty string when base URI is not set
    ///
    function test_contractURI_success_returnsEmptyStringWithoutBaseURI(address initialOwner) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        BuilderCodes freshContract = _deployFreshBuilderCodes();

        // Initialize with empty URI prefix
        freshContract.initialize(initialOwner, address(0), "");

        assertEq(freshContract.contractURI(), "");
    }

    /// @notice Test that contractURI reflects updated base URI
    ///
    /// @param newBaseURI The new base URI
    function test_contractURI_success_reflectsUpdatedBaseURI(string memory newBaseURI) public {
        // Update base URI using owner permissions
        vm.prank(owner);
        builderCodes.updateBaseURI(newBaseURI);

        string memory contractURI = builderCodes.contractURI();
        if (bytes(newBaseURI).length > 0) {
            string memory expected = string.concat(newBaseURI, "contractURI.json");
            assertEq(contractURI, expected);
        } else {
            assertEq(contractURI, "");
        }
    }

    /// @notice Test that contractURI returns contractURI.json suffix
    ///
    /// @param baseURI The base URI
    function test_contractURI_success_returnsWithCorrectSuffix(string memory baseURI) public {
        vm.assume(bytes(baseURI).length > 0);

        vm.prank(owner);
        builderCodes.updateBaseURI(baseURI);

        string memory contractURI = builderCodes.contractURI();
        string memory expected = string.concat(baseURI, "contractURI.json");
        assertEq(contractURI, expected);
    }
}
