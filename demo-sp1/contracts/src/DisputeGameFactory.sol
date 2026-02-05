// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DisputeGame.sol";
import "./OutputOracle.sol";

/// @title Dispute Game Factory
/// @notice Creates and tracks dispute games
contract DisputeGameFactory {
    /// @notice Output oracle reference
    OutputOracle public outputOracle;

    /// @notice SP1 verifier address
    address public sp1Verifier;

    /// @notice Block verify program verification key
    bytes32 public blockVerifyVkey;

    /// @notice Owner
    address public owner;

    /// @notice All created games
    DisputeGame[] public games;

    /// @notice Game by batch index
    mapping(uint256 => DisputeGame) public gameByBatch;

    /// @notice Events
    event GameCreated(uint256 indexed batchIndex, address game, address challenger);

    constructor(
        address _outputOracle,
        address _sp1Verifier,
        bytes32 _blockVerifyVkey
    ) {
        outputOracle = OutputOracle(_outputOracle);
        sp1Verifier = _sp1Verifier;
        blockVerifyVkey = _blockVerifyVkey;
        owner = msg.sender;
    }

    /// @notice Create a new dispute game
    /// @param _batchIndex Batch to dispute
    /// @param _challengerTraceHash Challenger's claimed trace hash
    function createGame(
        uint256 _batchIndex,
        bytes32 _challengerTraceHash
    ) external payable returns (DisputeGame) {
        require(address(gameByBatch[_batchIndex]) == address(0), "Game already exists");
        require(outputOracle.hasOutput(_batchIndex), "Batch not found");

        DisputeGame game = new DisputeGame{value: msg.value}(
            address(outputOracle),
            sp1Verifier,
            blockVerifyVkey,
            _batchIndex,
            _challengerTraceHash
        );

        games.push(game);
        gameByBatch[_batchIndex] = game;

        emit GameCreated(_batchIndex, address(game), msg.sender);

        return game;
    }

    /// @notice Get total games count
    function gamesCount() external view returns (uint256) {
        return games.length;
    }

    /// @notice Check if a batch has an active dispute
    function hasActiveDispute(uint256 _batchIndex) external view returns (bool) {
        DisputeGame game = gameByBatch[_batchIndex];
        if (address(game) == address(0)) return false;
        return game.status() == Types.GameStatus.IN_PROGRESS;
    }

    /// @notice Update SP1 verifier (owner only)
    function setVerifier(address _sp1Verifier) external {
        require(msg.sender == owner, "Not owner");
        sp1Verifier = _sp1Verifier;
    }

    /// @notice Update vkey (owner only)
    function setVkey(bytes32 _blockVerifyVkey) external {
        require(msg.sender == owner, "Not owner");
        blockVerifyVkey = _blockVerifyVkey;
    }
}
