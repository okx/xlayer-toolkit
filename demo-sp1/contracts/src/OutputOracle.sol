// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./lib/Types.sol";

/// @title Output Oracle
/// @notice Stores batch outputs submitted by proposer
contract OutputOracle {
    /// @notice Output structure
    struct Output {
        bytes32 stateHash;
        bytes32 traceHash;
        bytes32 smtRoot;
        uint64 startBlock;
        uint64 endBlock;
        uint256 timestamp;
        address proposer;
    }

    /// @notice Outputs by batch index
    mapping(uint256 => Output) public outputs;

    /// @notice Next batch index
    uint256 public nextBatchIndex;

    /// @notice Proposer address (for demo, single proposer)
    address public proposer;

    /// @notice Owner
    address public owner;

    /// @notice Events
    event OutputSubmitted(
        uint256 indexed batchIndex,
        bytes32 stateHash,
        bytes32 traceHash,
        bytes32 smtRoot,
        uint64 startBlock,
        uint64 endBlock
    );
    event OutputDeleted(uint256 indexed batchIndex);

    constructor(address _proposer) {
        proposer = _proposer;
        owner = msg.sender;
    }

    /// @notice Submit a new output
    function submitOutput(
        bytes32 _stateHash,
        bytes32 _traceHash,
        bytes32 _smtRoot,
        uint64 _startBlock,
        uint64 _endBlock
    ) external returns (uint256) {
        require(msg.sender == proposer, "Only proposer");
        require(_endBlock > _startBlock, "Invalid block range");

        uint256 batchIndex = nextBatchIndex++;

        outputs[batchIndex] = Output({
            stateHash: _stateHash,
            traceHash: _traceHash,
            smtRoot: _smtRoot,
            startBlock: _startBlock,
            endBlock: _endBlock,
            timestamp: block.timestamp,
            proposer: msg.sender
        });

        emit OutputSubmitted(batchIndex, _stateHash, _traceHash, _smtRoot, _startBlock, _endBlock);

        return batchIndex;
    }

    /// @notice Delete an output (called by dispute game on challenger win)
    function deleteOutput(uint256 _batchIndex) external {
        // Only dispute game factory can delete (for demo, allow owner)
        require(msg.sender == owner, "Not authorized");
        delete outputs[_batchIndex];
        emit OutputDeleted(_batchIndex);
    }

    /// @notice Get output
    function getOutput(uint256 _batchIndex) external view returns (Output memory) {
        return outputs[_batchIndex];
    }

    /// @notice Check if output exists
    function hasOutput(uint256 _batchIndex) external view returns (bool) {
        return outputs[_batchIndex].timestamp > 0;
    }
}
