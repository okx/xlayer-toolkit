// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BuilderCodes} from "../../../src/BuilderCodes.sol";

// Create a mock V2 contract for testing upgrades
contract MockBuilderCodesV2 is BuilderCodes {
    /// @notice Returns the domain name and version for the referral codes
    ///
    /// @return name The domain name for the referral codes
    /// @return version The version of the referral codes
    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "Builder Codes";
        version = "2";
    }
}
