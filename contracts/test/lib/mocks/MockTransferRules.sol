// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BuilderCodes} from "../../../src/BuilderCodes.sol";

contract MockTransferRules {
    BuilderCodes public builderCodes;

    mapping(address => mapping(address => bool)) public approvedTransfers;

    constructor(address builderCodes_) {
        builderCodes = BuilderCodes(builderCodes_);
    }

    function approveTransfer(address from, address to) public {
        if (!builderCodes.hasRole(builderCodes.TRANSFER_ROLE(), msg.sender)) revert();
        approvedTransfers[from][to] = true;
    }

    function transfer(address to, uint256 tokenId) public {
        if (!approvedTransfers[msg.sender][to]) revert();
        builderCodes.transferFrom(msg.sender, to, tokenId);
    }
}
