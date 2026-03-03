// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BuilderCodes} from "../../../src/BuilderCodes.sol";
import {BuilderCodesTest} from "../../lib/BuilderCodesTest.sol";

/// @notice Unit tests for BuilderCodes.payoutAddress (both overloads)
contract PayoutAddressTest is BuilderCodesTest {
    /// @notice Test that payoutAddress(string) reverts when code is not registered
    ///
    /// @param codeSeed The seed for generating the code
    function test_payoutAddressString_revert_unregistered(uint256 codeSeed) public {
        string memory code = _generateValidCode(codeSeed);

        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.Unregistered.selector, code));
        builderCodes.payoutAddress(code);
    }

    /// @notice Test that payoutAddress(string) reverts when code is empty
    function test_payoutAddressString_revert_emptyCode() public {
        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, ""));
        builderCodes.payoutAddress("");
    }

    /// @notice Test that payoutAddress(string) reverts when code is over 32 characters
    ///
    /// @param codeSeed The seed for generating the code
    function test_payoutAddressString_revert_codeOver32Characters(uint256 codeSeed) public {
        string memory longCode = _generateLongCode(codeSeed);

        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, longCode));
        builderCodes.payoutAddress(longCode);
    }

    /// @notice Test that payoutAddress(string) reverts when code contains invalid characters
    ///
    /// @param codeSeed The seed for generating the code
    function test_payoutAddressString_revert_codeContainsInvalidCharacters(uint256 codeSeed) public {
        string memory invalidCode = _generateInvalidCode(codeSeed);

        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, invalidCode));
        builderCodes.payoutAddress(invalidCode);
    }

    /// @notice Test that payoutAddress(uint256) reverts when token ID is not registered
    ///
    /// @param tokenId The token ID
    function test_payoutAddressUint256_revert_unregistered(uint256 tokenId) public {
        // Generate a valid token ID but don't register it
        string memory code = _generateValidCode(tokenId);
        uint256 validTokenId = builderCodes.toTokenId(code);

        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.Unregistered.selector, code));
        builderCodes.payoutAddress(validTokenId);
    }

    /// @notice Test that payoutAddress(uint256) reverts when token ID represents empty code
    function test_payoutAddressUint256_revert_emptyCode() public {
        uint256 emptyTokenId = 0;

        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, ""));
        builderCodes.payoutAddress(emptyTokenId);
    }

    /// @notice Test that payoutAddress(uint256) reverts when token ID represents code with invalid characters
    ///
    /// @param codeSeed The token ID representing invalid code
    function test_payoutAddressUint256_revert_codeContainsInvalidCharacters(uint256 codeSeed) public {
        // Use an invalid token ID that doesn't normalize properly
        string memory invalidCode = _generateInvalidCode(codeSeed);
        uint256 invalidTokenId = uint256(bytes32(bytes(invalidCode))) >> ((32 - bytes(invalidCode).length) * 8);

        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, invalidCode));
        builderCodes.payoutAddress(invalidTokenId);
    }

    /// @notice Test that payoutAddress(string) returns correct address for registered code
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param initialPayoutAddress The initial payout address
    function test_payoutAddressString_success_returnsCorrectAddress(
        uint256 codeSeed,
        address initialOwner,
        address initialPayoutAddress
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        initialPayoutAddress = _boundNonZeroAddress(initialPayoutAddress);

        string memory code = _generateValidCode(codeSeed);

        // Register the code first
        vm.prank(registrar);
        builderCodes.register(code, initialOwner, initialPayoutAddress);

        address retrievedAddress = builderCodes.payoutAddress(code);
        assertEq(retrievedAddress, initialPayoutAddress);
    }

    /// @notice Test that payoutAddress(uint256) returns correct address for registered token
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param initialPayoutAddress The initial payout address
    function test_payoutAddressUint256_success_returnsCorrectAddress(
        uint256 codeSeed,
        address initialOwner,
        address initialPayoutAddress
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        initialPayoutAddress = _boundNonZeroAddress(initialPayoutAddress);

        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);

        // Register the code first
        vm.prank(registrar);
        builderCodes.register(code, initialOwner, initialPayoutAddress);

        address retrievedAddress = builderCodes.payoutAddress(tokenId);
        assertEq(retrievedAddress, initialPayoutAddress);
    }

    /// @notice Test that both overloads return the same address for equivalent inputs
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param initialPayoutAddress The initial payout address
    function test_payoutAddress_success_overloadsReturnSameAddress(
        uint256 codeSeed,
        address initialOwner,
        address initialPayoutAddress
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        initialPayoutAddress = _boundNonZeroAddress(initialPayoutAddress);

        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);

        // Register the code first
        vm.prank(registrar);
        builderCodes.register(code, initialOwner, initialPayoutAddress);

        address addressFromString = builderCodes.payoutAddress(code);
        address addressFromUint256 = builderCodes.payoutAddress(tokenId);

        assertEq(addressFromString, addressFromUint256);
    }

    /// @notice Test that payoutAddress reflects updated payout address
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param initialPayoutAddress The initial payout address
    /// @param newPayoutAddress The new payout address
    function test_payoutAddress_success_reflectsUpdatedAddress(
        uint256 codeSeed,
        address initialOwner,
        address initialPayoutAddress,
        address newPayoutAddress
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        initialPayoutAddress = _boundNonZeroAddress(initialPayoutAddress);
        newPayoutAddress = _boundNonZeroAddress(newPayoutAddress);
        vm.assume(initialPayoutAddress != newPayoutAddress);

        string memory code = _generateValidCode(codeSeed);

        // Register the code first
        vm.prank(registrar);
        builderCodes.register(code, initialOwner, initialPayoutAddress);

        // Verify initial payout address
        assertEq(builderCodes.payoutAddress(code), initialPayoutAddress);

        // Update payout address
        vm.prank(initialOwner);
        builderCodes.updatePayoutAddress(code, newPayoutAddress);

        // Verify updated payout address
        assertEq(builderCodes.payoutAddress(code), newPayoutAddress);
    }
}
