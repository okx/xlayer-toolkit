// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IAccessControl} from "openzeppelin-contracts/access/IAccessControl.sol";

import {BuilderCodesTest} from "../../lib/BuilderCodesTest.sol";

/// @notice Unit tests for BuilderCodes.safeTransferFrom
contract SafeTransferFromTest is BuilderCodesTest {
    /// @notice Test that safeTransferFrom(from, to, tokenId) reverts when the token owner doesn't have the transfer
    /// role
    ///
    /// @param from The from address
    /// @param to The to address
    /// @param codeSeed The seed for generating the code
    /// @param payoutAddress The payout address
    function test_safeTransferFrom_revert_tokenOwnerNoTransferRole(
        address from,
        address to,
        uint256 codeSeed,
        address payoutAddress
    ) public {
        from = _boundNonZeroAddress(from);
        to = _boundNonZeroAddress(to);
        vm.assume(from != to);
        vm.assume(!builderCodes.hasRole(TRANSFER_ROLE, from));
        vm.assume(!builderCodes.hasRole(TRANSFER_ROLE, to));
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        // Register the code
        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);
        vm.prank(owner);
        builderCodes.register(code, from, payoutAddress);

        // Attempt token transfer
        vm.prank(from);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, from, TRANSFER_ROLE)
        );
        builderCodes.safeTransferFrom(from, to, tokenId);

        // Verify the token was not transferred
        assertEq(builderCodes.ownerOf(tokenId), from);
        assertEq(builderCodes.balanceOf(from), 1);
        assertEq(builderCodes.balanceOf(to), 0);
    }

    /// @notice Test that safeTransferFrom(from, to, tokenId) reverts when the approved address doesn't have the
    /// transfer role
    ///
    /// @param from The from address
    /// @param to The to address
    /// @param codeSeed The seed for generating the code
    /// @param payoutAddress The payout address
    function test_safeTransferFrom_revert_approvedNoTransferRole(
        address from,
        address to,
        uint256 codeSeed,
        address payoutAddress
    ) public {
        from = _boundNonZeroAddress(from);
        to = _boundNonZeroAddress(to);
        vm.assume(from != to);
        vm.assume(!builderCodes.hasRole(TRANSFER_ROLE, from));
        vm.assume(!builderCodes.hasRole(TRANSFER_ROLE, to));
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        // Register the code
        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);
        vm.prank(owner);
        builderCodes.register(code, from, payoutAddress);

        // Approve `to` to transfer the token
        vm.prank(from);
        builderCodes.approve(to, tokenId);

        // Attempt token transfer
        vm.prank(to);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, to, TRANSFER_ROLE)
        );
        builderCodes.safeTransferFrom(from, to, tokenId);

        // Verify the token was not transferred
        assertEq(builderCodes.ownerOf(tokenId), from);
        assertEq(builderCodes.balanceOf(from), 1);
        assertEq(builderCodes.balanceOf(to), 0);
    }

    /// @notice Test that safeTransferFrom(from, to, tokenId, data) reverts when the token owner doesn't have the
    /// transfer role
    ///
    /// @param from The from address
    /// @param to The to address
    /// @param codeSeed The seed for generating the code
    /// @param payoutAddress The payout address
    /// @param data The data to pass to the receiver
    function test_safeTransferFrom_bytesData_revert_tokenOwnerNoTransferRole(
        address from,
        address to,
        uint256 codeSeed,
        address payoutAddress,
        bytes memory data
    ) public {
        from = _boundNonZeroAddress(from);
        to = _boundNonZeroAddress(to);
        vm.assume(from != to);
        vm.assume(!builderCodes.hasRole(TRANSFER_ROLE, from));
        vm.assume(!builderCodes.hasRole(TRANSFER_ROLE, to));
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        // Register the code
        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);
        vm.prank(owner);
        builderCodes.register(code, from, payoutAddress);

        // Attempt token transfer
        vm.prank(from);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, from, TRANSFER_ROLE)
        );
        builderCodes.safeTransferFrom(from, to, tokenId, data);

        // Verify the token was not transferred
        assertEq(builderCodes.ownerOf(tokenId), from);
        assertEq(builderCodes.balanceOf(from), 1);
        assertEq(builderCodes.balanceOf(to), 0);
    }

    /// @notice Test that safeTransferFrom(from, to, tokenId, data) reverts when the approved address doesn't have the
    /// transfer role
    ///
    /// @param from The from address
    /// @param to The to address
    /// @param codeSeed The seed for generating the code
    /// @param payoutAddress The payout address
    /// @param data The data to pass to the receiver
    function test_safeTransferFrom_bytesData_revert_approvedNoTransferRole(
        address from,
        address to,
        uint256 codeSeed,
        address payoutAddress,
        bytes memory data
    ) public {
        from = _boundNonZeroAddress(from);
        to = _boundNonZeroAddress(to);
        vm.assume(from != to);
        vm.assume(!builderCodes.hasRole(TRANSFER_ROLE, from));
        vm.assume(!builderCodes.hasRole(TRANSFER_ROLE, to));
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        // Register the code
        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);
        vm.prank(owner);
        builderCodes.register(code, from, payoutAddress);

        // Approve `to` to transfer the token
        vm.prank(from);
        builderCodes.approve(to, tokenId);

        // Attempt token transfer
        vm.prank(to);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, to, TRANSFER_ROLE)
        );
        builderCodes.safeTransferFrom(from, to, tokenId, data);

        // Verify the token was not transferred
        assertEq(builderCodes.ownerOf(tokenId), from);
        assertEq(builderCodes.balanceOf(from), 1);
        assertEq(builderCodes.balanceOf(to), 0);
    }

    /// @notice Test that safeTransferFrom(from, to, tokenId) succeeds when the token owner has the transfer role
    ///
    /// @param from The from address
    /// @param to The to address
    /// @param codeSeed The seed for generating the code
    /// @param payoutAddress The payout address
    function test_safeTransferFrom_success_tokenOwnerHasTransferRole(
        address from,
        address to,
        uint256 codeSeed,
        address payoutAddress
    ) public {
        from = _boundNonZeroAddress(from);
        to = _boundNonZeroAddress(to);
        vm.assume(from != to);
        vm.assume(to.code.length == 0); // Ensure to is not a contract address for safeTransferFrom
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        // Register the code
        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);
        vm.prank(owner);
        builderCodes.register(code, from, payoutAddress);

        // Grant the `from` the transfer role
        vm.prank(owner);
        builderCodes.grantRole(TRANSFER_ROLE, from);

        // Transfer the token from `from` to `to`
        vm.prank(from);
        builderCodes.safeTransferFrom(from, to, tokenId);

        // Verify the token was transferred
        assertEq(builderCodes.ownerOf(tokenId), to);
        assertEq(builderCodes.balanceOf(from), 0);
        assertEq(builderCodes.balanceOf(to), 1);
    }

    /// @notice Test that safeTransferFrom(from, to, tokenId) succeeds when the approved address has the transfer role
    ///
    /// @param from The from address
    /// @param to The to address
    /// @param codeSeed The seed for generating the code
    /// @param payoutAddress The payout address
    function test_safeTransferFrom_success_approvedHasTransferRole(
        address from,
        address to,
        uint256 codeSeed,
        address payoutAddress
    ) public {
        from = _boundNonZeroAddress(from);
        to = _boundNonZeroAddress(to);
        vm.assume(from != owner);
        vm.assume(from != to);
        vm.assume(to.code.length == 0); // Ensure to is not a contract address for safeTransferFrom
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        // Register the code
        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);
        vm.prank(owner);
        builderCodes.register(code, from, payoutAddress);

        // Approve `to` to transfer the token
        vm.prank(from);
        builderCodes.approve(to, tokenId);

        // Grant the `to` the transfer role
        vm.prank(owner);
        builderCodes.grantRole(TRANSFER_ROLE, to);

        // Transfer the token from `from` to `to`
        vm.prank(to);
        builderCodes.safeTransferFrom(from, to, tokenId);

        // Verify the token was transferred
        assertEq(builderCodes.ownerOf(tokenId), to);
        assertEq(builderCodes.balanceOf(from), 0);
        assertEq(builderCodes.balanceOf(to), 1);
    }

    /// @notice Test that safeTransferFrom(from, to, tokenId, data) succeeds when the token owner has the transfer role
    ///
    /// @param from The from address
    /// @param to The to address
    /// @param codeSeed The seed for generating the code
    /// @param payoutAddress The payout address
    /// @param data The data to pass to the receiver
    function test_safeTransferFrom_bytesData_success_tokenOwnerHasTransferRole(
        address from,
        address to,
        uint256 codeSeed,
        address payoutAddress,
        bytes memory data
    ) public {
        from = _boundNonZeroAddress(from);
        to = _boundNonZeroAddress(to);
        vm.assume(from != to);
        vm.assume(to.code.length == 0); // Ensure to is not a contract address for safeTransferFrom
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        // Register the code
        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);
        vm.prank(owner);
        builderCodes.register(code, from, payoutAddress);

        // Grant the `from` the transfer role
        vm.prank(owner);
        builderCodes.grantRole(TRANSFER_ROLE, from);

        // Transfer the token from `from` to `to`
        vm.prank(from);
        builderCodes.safeTransferFrom(from, to, tokenId, data);

        // Verify the token was transferred
        assertEq(builderCodes.ownerOf(tokenId), to);
        assertEq(builderCodes.balanceOf(from), 0);
        assertEq(builderCodes.balanceOf(to), 1);
    }

    /// @notice Test that safeTransferFrom(from, to, tokenId, data) succeeds when the approved address has the transfer
    /// role
    ///
    /// @param from The from address
    /// @param to The to address
    /// @param codeSeed The seed for generating the code
    /// @param payoutAddress The payout address
    /// @param data The data to pass to the receiver
    function test_safeTransferFrom_bytesData_success_approvedHasTransferRole(
        address from,
        address to,
        uint256 codeSeed,
        address payoutAddress,
        bytes memory data
    ) public {
        from = _boundNonZeroAddress(from);
        to = _boundNonZeroAddress(to);
        vm.assume(from != owner);
        vm.assume(from != to);
        vm.assume(to.code.length == 0); // Ensure to is not a contract address for safeTransferFrom
        payoutAddress = _boundNonZeroAddress(payoutAddress);

        // Register the code
        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);
        vm.prank(owner);
        builderCodes.register(code, from, payoutAddress);

        // Approve `to` to transfer the token
        vm.prank(from);
        builderCodes.approve(to, tokenId);

        // Grant the `to` the transfer role
        vm.prank(owner);
        builderCodes.grantRole(TRANSFER_ROLE, to);

        // Transfer the token from `from` to `to`
        vm.prank(to);
        builderCodes.safeTransferFrom(from, to, tokenId, data);

        // Verify the token was transferred
        assertEq(builderCodes.ownerOf(tokenId), to);
        assertEq(builderCodes.balanceOf(from), 0);
        assertEq(builderCodes.balanceOf(to), 1);
    }
}
