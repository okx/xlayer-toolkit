// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BuilderCodesTest} from "../../lib/BuilderCodesTest.sol";

/// @notice Unit tests for BuilderCodes.supportsInterface
contract SupportsInterfaceTest is BuilderCodesTest {
    /// @notice Test that supportsInterface returns true for ERC165
    function test_supportsInterface_true_ERC165() public view {
        assertTrue(builderCodes.supportsInterface(0x01ffc9a7)); // ERC165 interface ID
    }

    /// @notice Test that supportsInterface returns true for ERC721
    function test_supportsInterface_true_ERC721() public view {
        assertTrue(builderCodes.supportsInterface(0x80ac58cd)); // ERC721 interface ID
    }

    /// @notice Test that supportsInterface returns true for ERC4906
    function test_supportsInterface_true_ERC4906() public view {
        assertTrue(builderCodes.supportsInterface(0x49064906)); // ERC4906 interface ID
    }

    /// @notice Test that supportsInterface returns true for AccessControl
    function test_supportsInterface_true_AccessControl() public view {
        assertTrue(builderCodes.supportsInterface(0x7965db0b)); // AccessControl interface ID
    }

    /// @notice Test that supportsInterface returns false for unsupported interfaces
    ///
    /// @param interfaceId The interface ID to test
    function test_supportsInterface_false_other(bytes4 interfaceId) public view {
        // Filter out known supported interface IDs
        vm.assume(interfaceId != 0x01ffc9a7); // ERC165
        vm.assume(interfaceId != 0x80ac58cd); // ERC721
        vm.assume(interfaceId != 0x49064906); // ERC4906
        vm.assume(interfaceId != 0x7965db0b); // AccessControl
        vm.assume(interfaceId != 0x5b5e139f); // ERC721Metadata

        assertFalse(builderCodes.supportsInterface(interfaceId));
    }
}
