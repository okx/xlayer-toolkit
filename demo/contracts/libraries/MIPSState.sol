// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {InvalidExitedValue} from "./CannonErrors.sol";

/**
 * @title MIPSState
 * @notice Library for MIPS VM state structures and utilities.
 */
library MIPSState {
    /// @notice CPU scalar values that change frequently during execution.
    struct CpuScalars {
        uint64 pc;      // Program counter
        uint64 nextPC;  // Next program counter (for branch delay slots)
        uint64 lo;      // LO register (multiplication/division result low)
        uint64 hi;      // HI register (multiplication/division result high)
    }

    /**
     * @notice Validate that the exited flag is 0 or 1.
     * @param _exited The exited flag value.
     */
    function assertExitedIsValid(uint32 _exited) internal pure {
        if (_exited > 1) {
            revert InvalidExitedValue();
        }
    }
}
