// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {BuilderCodesTest} from "../lib/BuilderCodesTest.sol";
import {MockTransferRules} from "../lib/mocks/MockTransferRules.sol";

/// @notice Integration tests for BuilderCodes transfers
contract BuilderCodesTransfersTest is BuilderCodesTest {
    function test_nonTransferableByDefault(address from, address to, uint256 codeSeed, address payoutAddress) public {
        from = _boundNonZeroAddress(from);
        to = _boundNonZeroAddress(to);
        vm.assume(!builderCodes.hasRole(TRANSFER_ROLE, from));
        vm.assume(from != to);
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);
        vm.prank(owner);
        builderCodes.register(code, from, payoutAddress);

        // Attempt transfer from, safeTransferFrom, and safeTransferFrom with data
        vm.startPrank(from);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, from, TRANSFER_ROLE)
        );

        builderCodes.transferFrom(from, to, tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, from, TRANSFER_ROLE)
        );

        builderCodes.safeTransferFrom(from, to, tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, from, TRANSFER_ROLE)
        );
        builderCodes.safeTransferFrom(from, to, tokenId, bytes(""));

        // Verify the token was not transferred
        assertEq(builderCodes.ownerOf(tokenId), from);
        assertEq(builderCodes.balanceOf(from), 1);
        assertEq(builderCodes.balanceOf(to), 0);
    }

    /// @notice Test that transferFrom succeeds when a token owner approves transfer rules
    ///
    /// @param from The from address
    /// @param to The to address
    /// @param codeSeed The seed for generating the code
    /// @param payoutAddress The payout address
    function test_approveTransferRulesToTransferToken(address from, address to, uint256 codeSeed, address payoutAddress)
        public
    {
        from = _boundNonZeroAddress(from);
        to = _boundNonZeroAddress(to);
        vm.assume(from != owner);
        vm.assume(from != to);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        MockTransferRules mockTransferRules = new MockTransferRules(address(builderCodes));

        // Register the code
        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);
        vm.prank(owner);
        builderCodes.register(code, from, payoutAddress);

        // Owner grants transfer role to transfer rules
        vm.prank(owner);
        builderCodes.grantRole(TRANSFER_ROLE, address(mockTransferRules));

        // Owner approves specific transfer on rules
        vm.prank(owner);
        mockTransferRules.approveTransfer(from, to);

        // User approves transfer rules to transfer the token
        vm.prank(from);
        builderCodes.approve(address(mockTransferRules), tokenId);

        // Transfer the token from `from` to `to`
        vm.prank(from);
        mockTransferRules.transfer(to, tokenId);

        // Verify the token was transferred
        assertEq(builderCodes.ownerOf(tokenId), to);
        assertEq(builderCodes.balanceOf(from), 0);
        assertEq(builderCodes.balanceOf(to), 1);
    }

    /// @notice Test that transferred code preserves the payout address
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    /// @param secondOwner The second owner address
    /// @param newPayoutAddress The new payout address for testing updates
    function test_transferedCodePreservesPayoutAddress(
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress,
        address secondOwner,
        address newPayoutAddress
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        secondOwner = _boundNonZeroAddress(secondOwner);
        newPayoutAddress = _boundNonZeroAddress(newPayoutAddress);

        vm.assume(initialOwner != secondOwner);

        string memory code = _generateValidCode(codeSeed);

        // Register the code with initial owner and payout address
        vm.prank(registrar);
        builderCodes.register(code, initialOwner, payoutAddress);

        // Verify initial state
        uint256 tokenId = builderCodes.toTokenId(code);
        assertEq(builderCodes.ownerOf(tokenId), initialOwner);
        assertEq(builderCodes.payoutAddress(code), payoutAddress);

        // Transfer the code to second owner
        vm.prank(owner);
        builderCodes.grantRole(TRANSFER_ROLE, initialOwner);
        vm.prank(initialOwner);
        builderCodes.transferFrom(initialOwner, secondOwner, tokenId);

        // Verify ownership changed but payout address preserved
        assertEq(builderCodes.ownerOf(tokenId), secondOwner);
        assertEq(builderCodes.payoutAddress(code), payoutAddress, "Payout address should be preserved after transfer");

        // Verify new owner can update payout address
        vm.prank(secondOwner);
        builderCodes.updatePayoutAddress(code, newPayoutAddress);

        assertEq(builderCodes.payoutAddress(code), newPayoutAddress);
    }
}
