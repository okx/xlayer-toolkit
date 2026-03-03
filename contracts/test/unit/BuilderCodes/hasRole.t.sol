// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BuilderCodesTest} from "../../lib/BuilderCodesTest.sol";

/// @notice Unit tests for BuilderCodes.hasRole
contract HasRoleTest is BuilderCodesTest {
    /// @notice Test that the owner has any role
    ///
    /// @param role The role to check
    function test_hasRole_true_isOwner(bytes32 role) public view {
        assertTrue(builderCodes.hasRole(role, owner));
    }

    /// @notice Test that a non-owner account with a role returns true from hasRole
    ///
    /// @param role The role to check
    /// @param account The non-owner account to check
    function test_hasRole_true_nonOwnerHasRole(bytes32 role, address account) public {
        account = _boundNonZeroAddress(account);
        vm.assume(account != owner);

        // Grant the role to the account
        vm.prank(owner);
        builderCodes.grantRole(role, account);

        assertTrue(builderCodes.hasRole(role, account));
    }

    /// @notice Test that a non-owner account without the role does not have a success return from hasRole
    ///
    /// @param role The role to check
    /// @param account The non-owner account to check
    function test_hasRole_false_other(bytes32 role, address account) public {
        account = _boundNonZeroAddress(account);
        vm.assume(account != owner);

        // Ensure the account doesn't have the role
        vm.prank(owner);
        builderCodes.revokeRole(role, account);

        assertFalse(builderCodes.hasRole(role, account));
    }
}
