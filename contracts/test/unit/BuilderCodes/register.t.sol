// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {BuilderCodes} from "../../../src/BuilderCodes.sol";

import {BuilderCodesTest, IERC721Errors} from "../../lib/BuilderCodesTest.sol";

/// @notice Unit tests for BuilderCodes.register
contract RegisterTest is BuilderCodesTest {
    /// @notice Test that register reverts when sender doesn't have required role
    ///
    /// @param sender The sender address
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    function test_register_revert_senderInvalidRole(
        address sender,
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress
    ) public {
        sender = _boundNonZeroAddress(sender);
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        vm.assume(sender != owner && sender != registrar);

        string memory code = _generateValidCode(codeSeed);

        vm.startPrank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, sender, builderCodes.REGISTER_ROLE()
            )
        );
        builderCodes.register(code, initialOwner, payoutAddress);
    }

    /// @notice Test that register reverts when attempting to register an empty code
    ///
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    function test_register_revert_emptyCode(address initialOwner, address payoutAddress) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, ""));
        builderCodes.register("", initialOwner, payoutAddress);
    }

    /// @notice Test that register reverts when the code is over 32 characters
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    function test_register_revert_codeOver32Characters(uint256 codeSeed, address initialOwner, address payoutAddress)
        public
    {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        string memory longCode = _generateLongCode(codeSeed);

        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, longCode));
        builderCodes.register(longCode, initialOwner, payoutAddress);
    }

    /// @notice Test that register reverts when the code contains invalid characters
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    function test_register_revert_codeContainsInvalidCharacters(
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        string memory invalidCode = _generateInvalidCode(codeSeed);

        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, invalidCode));
        builderCodes.register(invalidCode, initialOwner, payoutAddress);
    }

    /// @notice Test that register reverts when the initial owner is zero address
    ///
    /// @param codeSeed The seed for generating the code
    /// @param payoutAddress The payout address
    function test_register_revert_zeroInitialOwner(uint256 codeSeed, address payoutAddress) public {
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        string memory code = _generateValidCode(codeSeed);

        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        builderCodes.register(code, address(0), payoutAddress);
    }

    /// @notice Test that register reverts when the payout address is zero address
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    function test_register_revert_zeroPayoutAddress(uint256 codeSeed, address initialOwner) public {
        initialOwner = _boundNonZeroAddress(initialOwner);

        string memory code = _generateValidCode(codeSeed);

        vm.prank(registrar);
        vm.expectRevert(BuilderCodes.ZeroAddress.selector);
        builderCodes.register(code, initialOwner, address(0));
    }

    /// @notice Test that register reverts when the code is already registered
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    function test_register_revert_alreadyRegistered(uint256 codeSeed, address initialOwner, address payoutAddress)
        public
    {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        string memory code = _generateValidCode(codeSeed);

        // Register the code first
        vm.prank(registrar);
        builderCodes.register(code, initialOwner, payoutAddress);

        // Try to register the same code again
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidSender.selector, address(0)));
        builderCodes.register(code, initialOwner, payoutAddress);
    }

    /// @notice Test that register successfully mints a token
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    function test_register_success_mintsToken(uint256 codeSeed, address initialOwner, address payoutAddress) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);

        vm.prank(registrar);
        builderCodes.register(code, initialOwner, payoutAddress);

        assertEq(builderCodes.ownerOf(tokenId), initialOwner);
        assertTrue(builderCodes.isRegistered(code));
    }

    /// @notice Test that register can be called by owner
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    function test_register_success_ownerCanRegister(uint256 codeSeed, address initialOwner, address payoutAddress)
        public
    {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);

        vm.prank(owner);
        builderCodes.register(code, initialOwner, payoutAddress);

        assertEq(builderCodes.ownerOf(tokenId), initialOwner);
        assertTrue(builderCodes.isRegistered(code));
    }

    /// @notice Test that register successfully sets the payout address
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    function test_register_success_setsPayoutAddress(uint256 codeSeed, address initialOwner, address payoutAddress)
        public
    {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        string memory code = _generateValidCode(codeSeed);

        vm.prank(registrar);
        builderCodes.register(code, initialOwner, payoutAddress);

        assertEq(builderCodes.payoutAddress(code), payoutAddress);
    }

    /// @notice Test that register emits the ERC721 Transfer event
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    function test_register_success_emitsERC721Transfer(uint256 codeSeed, address initialOwner, address payoutAddress)
        public
    {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);

        vm.expectEmit(true, true, true, true);
        emit IERC721.Transfer(address(0), initialOwner, tokenId);

        vm.prank(registrar);
        builderCodes.register(code, initialOwner, payoutAddress);
    }

    /// @notice Test that register emits the CodeRegistered event
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    function test_register_success_emitsCodeRegistered(uint256 codeSeed, address initialOwner, address payoutAddress)
        public
    {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);

        vm.expectEmit(true, true, true, true);
        emit BuilderCodes.CodeRegistered(tokenId, code);

        vm.prank(registrar);
        builderCodes.register(code, initialOwner, payoutAddress);
    }

    /// @notice Test that register emits the PayoutAddressUpdated event
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    function test_register_success_emitsPayoutAddressUpdated(
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);

        vm.expectEmit(true, true, true, true);
        emit BuilderCodes.PayoutAddressUpdated(tokenId, payoutAddress);

        vm.prank(registrar);
        builderCodes.register(code, initialOwner, payoutAddress);
    }
}
