// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BuilderCodes} from "../../../src/BuilderCodes.sol";
import {BuilderCodesTest, IERC721Errors} from "../../lib/BuilderCodesTest.sol";

/// @notice Unit tests for BuilderCodes.updatePayoutAddress
contract UpdatePayoutAddressTest is BuilderCodesTest {
    /// @notice Test that updatePayoutAddress reverts when called with an invalid code
    ///
    /// @param codeSeed The seed for generating the invalid code
    /// @param payoutAddress The payout address to test
    function test_updatePayoutAddress_revert_invalidCode(uint256 codeSeed, address payoutAddress) public {
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        string memory invalidCode = _generateInvalidCode(codeSeed);

        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, invalidCode));
        builderCodes.updatePayoutAddress(invalidCode, payoutAddress);
    }

    /// @notice Test that updatePayoutAddress reverts when the code is not registered
    ///
    /// @param codeSeed The seed for generating the unregistered code
    /// @param payoutAddress The payout address to test
    function test_updatePayoutAddress_revert_codeNotRegistered(uint256 codeSeed, address payoutAddress) public {
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        string memory unregisteredCode = _generateValidCode(codeSeed);

        // The function calls _requireOwned which throws ERC721NonexistentToken for unregistered codes
        uint256 tokenId = builderCodes.toTokenId(unregisteredCode);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId));
        builderCodes.updatePayoutAddress(unregisteredCode, payoutAddress);
    }

    /// @notice Test that updatePayoutAddress reverts when the payout address is zero address
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param initialPayoutAddress The initial payout address
    function test_updatePayoutAddress_revert_unauthorized(
        address sender,
        uint256 codeSeed,
        address initialOwner,
        address initialPayoutAddress
    ) public {
        vm.assume(sender != initialOwner);
        initialOwner = _boundNonZeroAddress(initialOwner);
        initialPayoutAddress = _boundNonZeroAddress(initialPayoutAddress);

        string memory validCode = _generateValidCode(codeSeed);

        // First register a code
        vm.prank(registrar);
        builderCodes.register(validCode, initialOwner, initialPayoutAddress);

        // Try to update with zero address - should revert with unauthorized first since msg.sender != owner
        vm.prank(sender);
        vm.expectRevert(BuilderCodes.Unauthorized.selector);
        builderCodes.updatePayoutAddress(validCode, address(0));

        // Validate the payout address was not updated
        assertEq(builderCodes.payoutAddress(validCode), initialPayoutAddress);
    }

    /// @notice Test that updatePayoutAddress reverts when the payout address is zero address
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param initialPayoutAddress The initial payout address
    function test_updatePayoutAddress_revert_zeroPayoutAddress(
        uint256 codeSeed,
        address initialOwner,
        address initialPayoutAddress
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        vm.assume(initialOwner != address(this));
        initialPayoutAddress = _boundNonZeroAddress(initialPayoutAddress);

        string memory validCode = _generateValidCode(codeSeed);

        // First register a code
        vm.prank(registrar);
        builderCodes.register(validCode, initialOwner, initialPayoutAddress);

        // Try to update with zero address - should revert with zero address
        vm.prank(initialOwner);
        vm.expectRevert(BuilderCodes.ZeroAddress.selector);
        builderCodes.updatePayoutAddress(validCode, address(0));

        // Validate the payout address was not updated
        assertEq(builderCodes.payoutAddress(validCode), initialPayoutAddress);
    }

    /// @notice Test that updatePayoutAddress successfully updates the payout address
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param initialPayoutAddress The initial payout address
    /// @param newPayoutAddress The new payout address to test
    function test_updatePayoutAddress_success_payoutAddressUpdated(
        uint256 codeSeed,
        address initialOwner,
        address initialPayoutAddress,
        address newPayoutAddress
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        initialPayoutAddress = _boundNonZeroAddress(initialPayoutAddress);
        newPayoutAddress = _boundNonZeroAddress(newPayoutAddress);

        string memory validCode = _generateValidCode(codeSeed);

        // First register a code
        vm.prank(registrar);
        builderCodes.register(validCode, initialOwner, initialPayoutAddress);

        // Update the payout address
        vm.prank(initialOwner);
        builderCodes.updatePayoutAddress(validCode, newPayoutAddress);

        // Verify the payout address was updated
        assertEq(builderCodes.payoutAddress(validCode), newPayoutAddress);
    }

    /// @notice Test that updatePayoutAddress allows new owner to update the payout address
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param initialPayoutAddress The initial payout address
    /// @param newOwner The new owner address
    /// @param newPayoutAddress The new payout address to test
    function test_updatePayoutAddress_success_newOwnerCanUpdate(
        uint256 codeSeed,
        address initialOwner,
        address initialPayoutAddress,
        address newOwner,
        address newPayoutAddress
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        initialPayoutAddress = _boundNonZeroAddress(initialPayoutAddress);
        newOwner = _boundNonZeroAddress(newOwner);
        newPayoutAddress = _boundNonZeroAddress(newPayoutAddress);

        vm.assume(newOwner != initialOwner);

        string memory validCode = _generateValidCode(codeSeed);

        // First register a code
        vm.prank(registrar);
        builderCodes.register(validCode, initialOwner, initialPayoutAddress);

        // Transfer the token to new owner
        uint256 tokenId = builderCodes.toTokenId(validCode);
        vm.prank(owner);
        builderCodes.grantRole(TRANSFER_ROLE, initialOwner);
        vm.prank(initialOwner);
        builderCodes.transferFrom(initialOwner, newOwner, tokenId);

        // New owner should be able to update the payout address
        vm.prank(newOwner);
        builderCodes.updatePayoutAddress(validCode, newPayoutAddress);

        // Verify the payout address was updated
        assertEq(builderCodes.payoutAddress(validCode), newPayoutAddress);
    }

    /// @notice Test that updatePayoutAddress emits the PayoutAddressUpdated event
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param initialPayoutAddress The initial payout address
    /// @param newPayoutAddress The new payout address to test
    function test_updatePayoutAddress_success_emitsPayoutAddressUpdated(
        uint256 codeSeed,
        address initialOwner,
        address initialPayoutAddress,
        address newPayoutAddress
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        initialPayoutAddress = _boundNonZeroAddress(initialPayoutAddress);
        newPayoutAddress = _boundNonZeroAddress(newPayoutAddress);

        string memory validCode = _generateValidCode(codeSeed);

        // First register a code
        vm.prank(registrar);
        builderCodes.register(validCode, initialOwner, initialPayoutAddress);

        uint256 tokenId = builderCodes.toTokenId(validCode);

        // Expect the PayoutAddressUpdated event
        vm.expectEmit(true, true, true, true);
        emit BuilderCodes.PayoutAddressUpdated(tokenId, newPayoutAddress);

        // Update the payout address
        vm.prank(initialOwner);
        builderCodes.updatePayoutAddress(validCode, newPayoutAddress);
    }
}
