// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Anti-fork test helper: emits the standard ERC20-shaped Transfer
///         event with arbitrary indexed address topics, so a deposit tx that
///         calls this contract can deliberately trigger the blacklist's
///         committed event-log scan on a target address.
contract FakeTransferEmitter {
    event Transfer(address indexed from, address indexed to, uint256 value);

    function emitFakeTransfer(address from, address to, uint256 value) external {
        emit Transfer(from, to, value);
    }
}
