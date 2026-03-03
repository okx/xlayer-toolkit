// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BuilderCodesTest} from "../lib/BuilderCodesTest.sol";

/// @notice Integration tests for BuilderCodes operations
contract BuilderCodesAdminOperationsTest is BuilderCodesTest {
    /// @notice Test that adding many registrars works
    ///
    /// @param testOwner The owner address for testing
    /// @param testPayoutAddress The payout address for testing
    /// @param registrar1 First registrar address
    /// @param registrar2 Second registrar address
    /// @param registrar3 Third registrar address
    /// @param registrar4 Fourth registrar address
    /// @param registrar5 Fifth registrar address
    function test_addManyRegistrars(
        address testOwner,
        address testPayoutAddress,
        address registrar1,
        address registrar2,
        address registrar3,
        address registrar4,
        address registrar5
    ) public {
        testOwner = _boundNonZeroAddress(testOwner);
        testPayoutAddress = _boundNonZeroAddress(testPayoutAddress);
        registrar1 = _boundNonZeroAddress(registrar1);
        registrar2 = _boundNonZeroAddress(registrar2);
        registrar3 = _boundNonZeroAddress(registrar3);
        registrar4 = _boundNonZeroAddress(registrar4);
        registrar5 = _boundNonZeroAddress(registrar5);

        // Assume all registrars are unique
        vm.assume(registrar1 != registrar2);
        vm.assume(registrar1 != registrar3);
        vm.assume(registrar1 != registrar4);
        vm.assume(registrar1 != registrar5);
        vm.assume(registrar2 != registrar3);
        vm.assume(registrar2 != registrar4);
        vm.assume(registrar2 != registrar5);
        vm.assume(registrar3 != registrar4);
        vm.assume(registrar3 != registrar5);
        vm.assume(registrar4 != registrar5);

        address[] memory newRegistrars = new address[](5);
        newRegistrars[0] = registrar1;
        newRegistrars[1] = registrar2;
        newRegistrars[2] = registrar3;
        newRegistrars[3] = registrar4;
        newRegistrars[4] = registrar5;

        // Grant REGISTER_ROLE to multiple addresses
        vm.startPrank(owner);
        for (uint256 i = 0; i < newRegistrars.length; i++) {
            builderCodes.grantRole(builderCodes.REGISTER_ROLE(), newRegistrars[i]);
            assertTrue(builderCodes.hasRole(builderCodes.REGISTER_ROLE(), newRegistrars[i]));
        }
        vm.stopPrank();

        // Verify each registrar can register codes

        for (uint256 i = 0; i < newRegistrars.length; i++) {
            string memory code = string(abi.encodePacked("test", vm.toString(i)));

            vm.prank(newRegistrars[i]);
            builderCodes.register(code, testOwner, testPayoutAddress);

            // Verify registration succeeded
            assertTrue(builderCodes.isRegistered(code));
            assertEq(builderCodes.ownerOf(builderCodes.toTokenId(code)), testOwner);
            assertEq(builderCodes.payoutAddress(code), testPayoutAddress);
        }

        // Verify original registrar still works
        string memory originalRegistrarCode = "originalregistrar";
        vm.prank(registrar);
        builderCodes.register(originalRegistrarCode, testOwner, testPayoutAddress);
        assertTrue(builderCodes.isRegistered(originalRegistrarCode));
    }

    /// @notice Test that revoking roles works
    ///
    /// @param tempRegistrar The temporary registrar address
    /// @param tempMetadataManager The temporary metadata manager address
    /// @param testOwner The test owner address
    /// @param testPayoutAddress The test payout address
    function test_revokeRoles(
        address tempRegistrar,
        address tempMetadataManager,
        address testOwner,
        address testPayoutAddress
    ) public {
        tempRegistrar = _boundNonZeroAddress(tempRegistrar);
        tempMetadataManager = _boundNonZeroAddress(tempMetadataManager);
        testOwner = _boundNonZeroAddress(testOwner);
        testPayoutAddress = _boundNonZeroAddress(testPayoutAddress);

        vm.assume(tempRegistrar != owner);
        vm.assume(tempRegistrar != tempMetadataManager);
        vm.assume(tempRegistrar != testOwner);
        vm.assume(tempRegistrar != registrar);
        vm.assume(tempRegistrar != owner);
        vm.assume(tempMetadataManager != testOwner);
        vm.assume(tempMetadataManager != owner);

        // Grant roles
        vm.startPrank(owner);
        builderCodes.grantRole(builderCodes.REGISTER_ROLE(), tempRegistrar);
        builderCodes.grantRole(builderCodes.METADATA_ROLE(), tempMetadataManager);
        vm.stopPrank();

        // Verify roles were granted
        assertTrue(builderCodes.hasRole(builderCodes.REGISTER_ROLE(), tempRegistrar));
        assertTrue(builderCodes.hasRole(builderCodes.METADATA_ROLE(), tempMetadataManager));

        // Test that temp registrar can register
        string memory testCode1 = "tempcode1";

        vm.prank(tempRegistrar);
        builderCodes.register(testCode1, testOwner, testPayoutAddress);
        assertTrue(builderCodes.isRegistered(testCode1));

        // Test that temp metadata manager can update metadata
        uint256 tokenId = builderCodes.toTokenId(testCode1);
        vm.prank(tempMetadataManager);
        builderCodes.updateMetadata(tokenId);

        // Revoke roles
        vm.startPrank(owner);
        builderCodes.revokeRole(builderCodes.REGISTER_ROLE(), tempRegistrar);
        builderCodes.revokeRole(builderCodes.METADATA_ROLE(), tempMetadataManager);
        vm.stopPrank();

        // Verify roles were revoked
        assertFalse(builderCodes.hasRole(builderCodes.REGISTER_ROLE(), tempRegistrar));
        assertFalse(builderCodes.hasRole(builderCodes.METADATA_ROLE(), tempMetadataManager));

        // Test that revoked registrar can no longer register
        string memory testCode2 = "tempcode2";
        vm.prank(tempRegistrar);
        vm.expectRevert();
        builderCodes.register(testCode2, testOwner, testPayoutAddress);

        // Test that revoked metadata manager can no longer update metadata
        vm.prank(tempMetadataManager);
        vm.expectRevert();
        builderCodes.updateMetadata(tokenId);

        // Verify original registrar still works
        string memory originalCode = "originalstillworks";
        vm.prank(registrar);
        builderCodes.register(originalCode, testOwner, testPayoutAddress);
        assertTrue(builderCodes.isRegistered(originalCode));
    }

    /// @notice Test that two step owner transfer works
    ///
    /// @param newOwner The new owner address
    /// @param tempRegistrar The temporary registrar address
    /// @param tempMetadataAddress The temporary metadata address
    /// @param randomAddress A random address for testing unauthorized access
    /// @param newMetadataManager The new metadata manager address
    function test_twoStepOwnerTransfer(
        address newOwner,
        address tempRegistrar,
        address tempMetadataAddress,
        address randomAddress,
        address newMetadataManager
    ) public {
        newOwner = _boundNonZeroAddress(newOwner);
        tempRegistrar = _boundNonZeroAddress(tempRegistrar);
        tempMetadataAddress = _boundNonZeroAddress(tempMetadataAddress);
        randomAddress = _boundNonZeroAddress(randomAddress);
        newMetadataManager = _boundNonZeroAddress(newMetadataManager);

        vm.assume(newOwner != owner);
        vm.assume(newOwner != tempRegistrar);
        vm.assume(newOwner != tempMetadataAddress);
        vm.assume(newOwner != randomAddress);
        vm.assume(newOwner != newMetadataManager);
        vm.assume(tempRegistrar != tempMetadataAddress);
        vm.assume(tempRegistrar != randomAddress);
        vm.assume(tempRegistrar != newMetadataManager);
        vm.assume(tempRegistrar != registrar);
        vm.assume(tempMetadataAddress != randomAddress);
        vm.assume(tempMetadataAddress != newMetadataManager);
        vm.assume(randomAddress != newMetadataManager);

        bytes32 registerRole = builderCodes.REGISTER_ROLE();
        bytes32 metadataRole = builderCodes.METADATA_ROLE();
        bytes32 defaultAdminRole = builderCodes.DEFAULT_ADMIN_ROLE();

        // Verify initial owner
        assertEq(builderCodes.owner(), owner);
        assertEq(builderCodes.pendingOwner(), address(0));

        // Step 1: Transfer ownership (only initiates transfer)
        vm.prank(owner);
        builderCodes.transferOwnership(newOwner);

        // Verify ownership hasn't changed yet, but pending owner is set
        assertEq(builderCodes.owner(), owner);
        assertEq(builderCodes.pendingOwner(), newOwner);

        // Verify old owner can still perform owner functions
        vm.prank(owner);
        builderCodes.grantRole(registerRole, tempRegistrar);
        assertTrue(builderCodes.hasRole(registerRole, tempRegistrar));

        // Verify new owner cannot perform owner functions yet
        vm.prank(newOwner);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, newOwner, defaultAdminRole)
        );
        builderCodes.grantRole(metadataRole, tempMetadataAddress);

        // Verify random address cannot accept ownership
        vm.prank(randomAddress);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomAddress));
        builderCodes.acceptOwnership();

        // Step 2: Accept ownership
        vm.prank(newOwner);
        builderCodes.acceptOwnership();

        // Verify ownership has now changed
        assertEq(builderCodes.owner(), newOwner);
        assertEq(builderCodes.pendingOwner(), address(0));

        // Verify old owner can no longer perform owner functions
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, defaultAdminRole)
        );
        builderCodes.grantRole(metadataRole, tempMetadataAddress);

        // Verify new owner can perform owner functions
        vm.prank(newOwner);
        builderCodes.grantRole(metadataRole, newMetadataManager);
        assertTrue(builderCodes.hasRole(metadataRole, newMetadataManager));

        // Verify new owner has hasRole override (owner always has all roles)
        assertTrue(builderCodes.hasRole(registerRole, newOwner));
        assertTrue(builderCodes.hasRole(metadataRole, newOwner));
    }
}
