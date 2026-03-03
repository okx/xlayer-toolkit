// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BuilderCodesTest} from "../../lib/BuilderCodesTest.sol";

import {BuilderCodes} from "../../../src/BuilderCodes.sol";

/// @notice Unit tests for BuilderCodes.renounceOwnership
contract RenounceOwnershipTest is BuilderCodesTest {
    /// @notice Test that renounceOwnership is disabled and reverts
    function test_renounceOwnership_revert_disabled() public {
        vm.prank(owner);
        vm.expectRevert(BuilderCodes.OwnershipRenunciationDisabled.selector);
        builderCodes.renounceOwnership();
    }
}
