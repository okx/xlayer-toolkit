// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BuilderCodesTest} from "../../lib/BuilderCodesTest.sol";

/// @notice Unit tests for BuilderCodes.isValidCode
contract IsValidCodeTest is BuilderCodesTest {
    /// @notice Test that isValidCode returns false for empty code
    function test_isValidCode_false_emptyCode() public view {
        assertFalse(builderCodes.isValidCode(""));
    }

    /// @notice Test that isValidCode returns false for code over 32 characters
    ///
    /// @param codeSeed The seed for generating the code
    function test_isValidCode_false_codeOver32Characters(uint256 codeSeed) public view {
        string memory longCode = _generateLongCode(codeSeed);
        assertFalse(builderCodes.isValidCode(longCode));
    }

    /// @notice Test that isValidCode returns false for code with invalid characters
    ///
    /// @param codeSeed The seed for generating the code
    function test_isValidCode_false_invalidCharacters(uint256 codeSeed) public view {
        string memory invalidCode = _generateInvalidCode(codeSeed);
        assertFalse(builderCodes.isValidCode(invalidCode));
    }

    /// @notice Test that isValidCode returns true for valid code
    ///
    /// @param codeSeed The seed for generating the code
    function test_isValidCode_true_validCode(uint256 codeSeed) public view {
        string memory validCode = _generateValidCode(codeSeed);
        assertTrue(builderCodes.isValidCode(validCode));
    }

    /// @notice Test that isValidCode returns true for single character valid code
    function test_isValidCode_true_singleCharacter() public view {
        assertTrue(builderCodes.isValidCode("a"));
        assertTrue(builderCodes.isValidCode("0"));
        assertTrue(builderCodes.isValidCode("_"));
    }

    /// @notice Test that isValidCode returns true for 32 character valid code
    function test_isValidCode_true_32Characters() public view {
        string memory code32 = "abcdefghijklmnopqrstuvwxyz012345";
        assertTrue(builderCodes.isValidCode(code32));
    }

    /// @notice Test that isValidCode returns true for code with underscores
    function test_isValidCode_true_underscores() public view {
        assertTrue(builderCodes.isValidCode("test_code"));
        assertTrue(builderCodes.isValidCode("_underscore_"));
    }

    /// @notice Test that isValidCode returns true for numeric only code
    function test_isValidCode_true_numericOnly() public view {
        assertTrue(builderCodes.isValidCode("1234567890"));
    }

    /// @notice Test that isValidCode returns true for alphabetic only code
    function test_isValidCode_true_alphabeticOnly() public view {
        assertTrue(builderCodes.isValidCode("abcdefghijklmnopqrstuvwxyz"));
    }
}
