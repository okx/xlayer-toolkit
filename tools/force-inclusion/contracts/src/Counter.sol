// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Counter {
    uint256 public count;

    event Incremented(address indexed sender, uint256 newCount);

    function increment() external {
        count++;
        emit Incremented(msg.sender, count);
    }
}
