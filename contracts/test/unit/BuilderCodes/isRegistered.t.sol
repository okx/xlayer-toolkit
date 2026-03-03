// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BuilderCodes} from "../../../src/BuilderCodes.sol";
import {BuilderCodesTest} from "../../lib/BuilderCodesTest.sol";

/// @notice Unit tests for BuilderCodes.isRegistered
contract IsRegisteredTest is BuilderCodesTest {
    /// @notice Test that isRegistered reverts when code is empty
    function test_isRegistered_revert_emptyCode() public {
        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, ""));
        builderCodes.isRegistered("");
    }

    /// @notice Test that isRegistered reverts when code is over 32 characters
    ///
    /// @param codeSeed The seed for generating the code
    function test_isRegistered_revert_codeOver32Characters(uint256 codeSeed) public {
        string memory longCode = _generateLongCode(codeSeed);
        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, longCode));
        builderCodes.isRegistered(longCode);
    }

    /// @notice Test that isRegistered reverts when code contains invalid characters
    ///
    /// @param codeSeed The seed for generating the code
    function test_isRegistered_revert_codeContainsInvalidCharacters(uint256 codeSeed) public {
        string memory invalidCode = _generateInvalidCode(codeSeed);
        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, invalidCode));
        builderCodes.isRegistered(invalidCode);
    }

    /// @notice Test that isRegistered returns false for unregistered valid code
    ///
    /// @param codeSeed The seed for generating the code
    function test_isRegistered_success_returnsFalseForUnregistered(uint256 codeSeed) public view {
        string memory validCode = _generateValidCode(codeSeed);
        assertFalse(builderCodes.isRegistered(validCode));
    }

    /// @notice Test that isRegistered returns true for registered code
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param initialPayoutAddress The initial payout address
    function test_isRegistered_success_returnsTrueForRegistered(
        uint256 codeSeed,
        address initialOwner,
        address initialPayoutAddress
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        initialPayoutAddress = _boundNonZeroAddress(initialPayoutAddress);
        string memory validCode = _generateValidCode(codeSeed);

        // Register the code
        vm.prank(registrar);
        builderCodes.register(validCode, initialOwner, initialPayoutAddress);

        assertTrue(builderCodes.isRegistered(validCode));
    }
}
