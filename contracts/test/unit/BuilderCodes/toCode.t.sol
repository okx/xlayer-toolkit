// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BuilderCodes} from "../../../src/BuilderCodes.sol";
import {BuilderCodesTest} from "../../lib/BuilderCodesTest.sol";

/// @notice Unit tests for BuilderCodes.toCode
contract ToCodeTest is BuilderCodesTest {
    /// @notice Test that toCode reverts when token ID represents empty code
    ///
    function test_toCode_revert_emptyCode() public {
        uint256 emptyTokenId = 0;
        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, ""));
        builderCodes.toCode(emptyTokenId);
    }

    /// @notice Test that toCode reverts when token ID represents code with invalid characters
    ///
    /// @param tokenId The token ID representing invalid code
    function test_toCode_revert_codeContainsInvalidCharacters(uint256 tokenId) public {
        // Use a token ID that would convert to invalid characters
        string memory invalidCode = _generateInvalidCode(tokenId);
        uint256 invalidTokenId = uint256(bytes32(bytes(invalidCode))) >> ((32 - bytes(invalidCode).length) * 8);
        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, invalidCode));
        builderCodes.toCode(invalidTokenId);
    }

    /// @notice Test that toCode reverts when token ID does not normalize properly
    ///
    /// @param seed The seed for generating the valid code
    /// @param zeroCharacter The character position to zero out
    function test_toCode_revert_invalidNormalization(uint256 seed, uint8 zeroCharacter) public {
        vm.assume(zeroCharacter > 0);
        string memory validCode = _generateValidCode(seed);
        vm.assume(bytes(validCode).length - 1 > zeroCharacter);
        uint256 validTokenId = builderCodes.toTokenId(validCode);
        uint256 invalidTokenId = validTokenId & (~(uint256(0xFF) << (8 * zeroCharacter)));
        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidTokenId.selector, invalidTokenId));
        builderCodes.toCode(invalidTokenId);
    }

    /// @notice Test that toCode returns correct code for valid token ID
    ///
    /// @param codeSeed The seed for generating the code
    function test_toCode_success_returnsCorrectCode(uint256 codeSeed) public view {
        string memory validCode = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(validCode);

        string memory retrievedCode = builderCodes.toCode(tokenId);
        assertEq(retrievedCode, validCode);
    }
}
