// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Types for ZK Bisection Dispute Game
library Types {
    /// @notice Game status
    enum GameStatus {
        IN_PROGRESS,
        CHALLENGER_WINS,
        DEFENDER_WINS
    }

    /// @notice Bisection status
    enum BisectionStatus {
        NOT_STARTED,
        IN_PROGRESS,
        COMPLETED
    }

    /// @notice Block output data
    struct BlockOutput {
        uint64 blockNumber;
        bytes32 blockHash;
        bytes32 stateHash;
        bytes32 traceHash;
        bytes32 smtRoot;
        uint32 successCount;
    }

    /// @notice Bisection claim
    struct BisectionClaim {
        uint64 blockNumber;      // Block number at this position
        bytes32 traceHash;       // Trace hash claimed at this position
        address claimant;        // Who made this claim
        bool isProposerClaim;    // True if proposer's claim, false if challenger's
    }
}
