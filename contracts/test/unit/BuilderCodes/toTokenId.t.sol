// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BuilderCodes} from "../../../src/BuilderCodes.sol";
import {BuilderCodesTest} from "../../lib/BuilderCodesTest.sol";

/// @notice Unit tests for BuilderCodes.toTokenId
contract ToTokenIdTest is BuilderCodesTest {
    /// @notice Test that toTokenId reverts when code is empty
    function test_toTokenId_revert_emptyCode() public {
        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, ""));
        builderCodes.toTokenId("");
    }

    /// @notice Test that toTokenId reverts when code is over 32 characters
    ///
    /// @param codeSeed The seed for generating the code
    function test_toTokenId_revert_codeOver32Characters(uint256 codeSeed) public {
        string memory longCode = _generateLongCode(codeSeed);
        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, longCode));
        builderCodes.toTokenId(longCode);
    }

    /// @notice Test that toTokenId reverts when code contains invalid characters
    ///
    /// @param codeSeed The seed for generating the code
    function test_toTokenId_revert_codeContainsInvalidCharacters(uint256 codeSeed) public {
        string memory invalidCode = _generateInvalidCode(codeSeed);
        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, invalidCode));
        builderCodes.toTokenId(invalidCode);
    }

    /// @notice Test that toTokenId returns correct token ID for valid code
    ///
    /// @param codeSeed The seed for generating the code
    function test_toTokenId_success_returnsCorrectTokenId(uint256 codeSeed) public view {
        string memory validCode = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(validCode);

        // Verify the conversion is bidirectional
        string memory convertedBack = builderCodes.toCode(tokenId);
        assertEq(validCode, convertedBack);
    }
}
