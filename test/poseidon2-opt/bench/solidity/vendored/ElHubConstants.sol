// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Constants {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_BATCH_ACTIONS = 50;
    uint256 internal constant SNARK_SCALAR_FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    uint8 internal constant INTENT_SUPPLY = 1;
    uint8 internal constant INTENT_REPAY = 2;
    uint8 internal constant INTENT_BORROW = 3;
    uint8 internal constant INTENT_WITHDRAW = 4;
}
