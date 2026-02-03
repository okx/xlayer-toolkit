// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./OutputOracle.sol";
import "./MIPS.sol";

/**
 * @title DisputeGame
 * @notice Interactive bisection dispute game integrated with Cannon MIPS VM.
 * @dev Uses bisection to find the exact instruction where disagreement occurs,
 *      then uses MIPS VM to verify the single-step execution.
 */
contract DisputeGame {
    /// @notice Claim structure for bisection game
    struct ClaimData {
        uint32 parentIndex;     // Parent claim index (uint32.max for root)
        address counteredBy;    // Address that countered this claim
        address claimant;       // Address that made this claim
        uint128 bond;           // Bond amount locked
        bytes32 claim;          // State hash at this position
        uint128 position;       // Position in game tree (gindex)
        uint128 clock;          // Time when claim was made
    }

    /// @notice Game status
    enum GameStatus {
        IN_PROGRESS,
        CHALLENGER_WINS,
        DEFENDER_WINS
    }

    /// @notice Move type for events
    event Move(
        uint256 indexed parentIndex,
        bytes32 indexed claim,
        address indexed claimant,
        uint256 position,
        bool isAttack
    );

    /// @notice Step execution event
    event Step(
        uint256 indexed claimIndex,
        bytes32 preStateHash,
        bytes32 postStateHash,
        bool valid
    );

    /// @notice Game resolved event
    event Resolved(GameStatus status, address winner);

    /// @notice The output oracle contract
    OutputOracle public outputOracle;

    /// @notice The MIPS VM contract
    MIPS public mipsVM;

    /// @notice The batch index being disputed
    uint256 public batchIndex;

    /// @notice The root claim (proposer's MPT root)
    bytes32 public rootClaim;

    /// @notice The challenger's claimed root
    bytes32 public challengerClaim;

    /// @notice Current game status
    GameStatus public status;

    /// @notice All claims in the game
    ClaimData[] public claimData;

    /// @notice Maximum game duration (for fast testing: 10 minutes)
    uint256 public constant MAX_GAME_DURATION = 10 minutes;

    /// @notice Max game depth (bisection steps)
    uint256 public constant MAX_DEPTH = 10; // Demo: reduced for faster bisection

    /// @notice Split depth (output vs execution trace)
    uint256 public constant SPLIT_DEPTH = 30;

    /// @notice Minimum bond for moves (0.01 ETH for testing)
    uint256 public constant MIN_BOND = 0.01 ether;

    /// @notice Game start timestamp
    uint256 public gameStart;

    /// @notice Game creator (challenger)
    address public challenger;

    /// @notice Factory address for callbacks
    address public factory;

    /// @notice L2 block number in dispute
    uint256 public l2BlockNumber;

    /// @notice Absolute prestate hash (initial VM state)
    bytes32 public absolutePrestate;

    /// @notice Whether step has been executed
    bool public stepExecuted;

    constructor(
        address _outputOracle,
        address _mipsVM,
        uint256 _batchIndex,
        bytes32 _challengerClaim
    ) {
        outputOracle = OutputOracle(_outputOracle);
        mipsVM = MIPS(_mipsVM);
        batchIndex = _batchIndex;
        challengerClaim = _challengerClaim;
        status = GameStatus.IN_PROGRESS;
        gameStart = block.timestamp;
        challenger = msg.sender;
        factory = msg.sender; // Factory creates this contract

        // Get the proposer's root claim from output oracle
        OutputOracle.OutputProposal memory output = outputOracle.getOutput(_batchIndex);
        require(output.timestamp > 0, "Output not found");
        rootClaim = output.mptRoot;
        l2BlockNumber = output.l2BlockNumber;

        // Initialize with the proposer's root claim at position 1
        claimData.push(ClaimData({
            parentIndex: type(uint32).max,
            counteredBy: address(0),
            claimant: address(0), // System/Proposer claim
            bond: 0,
            claim: rootClaim,
            position: 1, // Root position in binary tree
            clock: uint128(block.timestamp)
        }));
    }

    /**
     * @notice Attack a claim by bisecting left.
     * @param _parentIndex Index of the parent claim.
     * @param _claim The new claim value (state at midpoint).
     */
    function attack(uint256 _parentIndex, bytes32 _claim) external payable {
        _move(_parentIndex, _claim, true);
    }

    /**
     * @notice Defend a claim by bisecting right.
     * @param _parentIndex Index of the parent claim.
     * @param _claim The new claim value (state at midpoint).
     */
    function defend(uint256 _parentIndex, bytes32 _claim) external payable {
        _move(_parentIndex, _claim, false);
    }

    /**
     * @notice Internal move logic.
     */
    function _move(uint256 _parentIndex, bytes32 _claim, bool _isAttack) internal {
        require(status == GameStatus.IN_PROGRESS, "Game not in progress");
        require(msg.value >= MIN_BOND, "Insufficient bond");
        require(_parentIndex < claimData.length, "Invalid parent");
        require(block.timestamp < gameStart + MAX_GAME_DURATION, "Game expired");

        ClaimData storage parent = claimData[_parentIndex];
        require(parent.counteredBy == address(0), "Already countered");

        // Calculate new position
        uint128 newPosition;
        if (_isAttack) {
            // Attack: go to left child (position * 2)
            newPosition = parent.position * 2;
        } else {
            // Defend: go to right child (position * 2 + 1)
            newPosition = parent.position * 2 + 1;
        }

        // Check depth limit
        uint256 depth = _getDepth(newPosition);
        require(depth <= MAX_DEPTH, "Max depth reached");

        // Mark parent as countered
        parent.counteredBy = msg.sender;

        // Add new claim
        claimData.push(ClaimData({
            parentIndex: uint32(_parentIndex),
            counteredBy: address(0),
            claimant: msg.sender,
            bond: uint128(msg.value),
            claim: _claim,
            position: newPosition,
            clock: uint128(block.timestamp)
        }));

        emit Move(_parentIndex, _claim, msg.sender, newPosition, _isAttack);
    }

    /**
     * @notice Execute the final step to verify a leaf claim.
     * @param _claimIndex The claim index to step on.
     * @param _stateData The pre-state data (Cannon witness).
     * @param _proof The proof data (memory Merkle proof).
     * @param _claimedPostState The post-state hash computed by Cannon.
     */
    function step(
        uint256 _claimIndex,
        bytes calldata _stateData,
        bytes calldata _proof,
        bytes32 _claimedPostState
    ) external {
        require(status == GameStatus.IN_PROGRESS, "Game not in progress");
        require(_claimIndex < claimData.length, "Invalid claim");
        require(!stepExecuted, "Step already executed");

        ClaimData storage claim = claimData[_claimIndex];

        // Must be at max depth (leaf node)
        uint256 depth = _getDepth(claim.position);
        require(depth >= MAX_DEPTH - 1, "Not at step depth");

        // Get the claimed pre-state and post-state hashes from bisection
        bytes32 preStateHash;
        bytes32 postStateHash;

        // Determine which states to compare based on position
        if (_claimIndex > 0) {
            ClaimData storage parent = claimData[claim.parentIndex];
            preStateHash = parent.claim;
            postStateHash = claim.claim;
        } else {
            preStateHash = absolutePrestate;
            postStateHash = claim.claim;
        }

        // Execute single step in MIPS VM to verify the state transition
        // The MIPS contract verifies:
        // 1. The witness (_stateData) hashes to the claimed pre-state (preStateHash)
        // 2. Returns the claimed post-state if verification passes
        bytes32 computedPostState = mipsVM.step(_stateData, _proof, preStateHash, _claimedPostState);

        // Verify the computed post-state matches what Cannon provided
        // This ensures the witness data is valid and consistent
        require(computedPostState == _claimedPostState, "Post-state mismatch");

        // Determine validity: 
        // - If computedPostState matches the bisection claim, defender was correct
        // - If computedPostState differs, challenger proved the fault
        bool valid = (computedPostState == postStateHash);

        stepExecuted = true;
        claim.counteredBy = msg.sender;

        // Log the step execution with all state hashes for verification
        emit Step(_claimIndex, preStateHash, computedPostState, valid);
    }

    /**
     * @notice Resolve the game after time expires or step is executed.
     */
    function resolve() external {
        require(status == GameStatus.IN_PROGRESS, "Already resolved");
        require(
            block.timestamp >= gameStart + MAX_GAME_DURATION || stepExecuted,
            "Cannot resolve yet"
        );

        // Find the deepest uncountered claim
        address winner;
        bool challengerWins = false;

        for (uint256 i = claimData.length; i > 0; i--) {
            ClaimData storage claim = claimData[i - 1];
            if (claim.counteredBy == address(0)) {
                // Found uncountered claim
                uint256 depth = _getDepth(claim.position);

                // Odd depth = challenger's turn, even = defender's turn
                // Uncountered at odd depth = challenger wins
                // Uncountered at even depth = defender wins
                if (depth % 2 == 1) {
                    challengerWins = true;
                    winner = claim.claimant;
                } else {
                    winner = address(0); // Proposer/Defender
                }
                break;
            }
        }

        if (challengerWins) {
            status = GameStatus.CHALLENGER_WINS;
            // Delete the invalid output from oracle
            outputOracle.deleteOutput(batchIndex);
        } else {
            status = GameStatus.DEFENDER_WINS;
        }

        emit Resolved(status, winner);

        // Notify factory
        try IDisputeGameFactory(factory).onGameResolved(batchIndex, status) {} catch {}

        // Distribute bonds (simplified: send all to winner)
        if (winner != address(0) && address(this).balance > 0) {
            (bool success, ) = winner.call{value: address(this).balance}("");
            require(success, "Transfer failed");
        }
    }

    /**
     * @notice Get the depth of a position in the game tree.
     */
    function _getDepth(uint128 _position) internal pure returns (uint256) {
        uint256 depth = 0;
        uint128 p = _position;
        while (p > 1) {
            p = p / 2;
            depth++;
        }
        return depth;
    }

    /**
     * @notice Get the number of claims.
     */
    function claimCount() external view returns (uint256) {
        return claimData.length;
    }

    /**
     * @notice Get a specific claim.
     */
    function getClaim(uint256 _index) external view returns (ClaimData memory) {
        require(_index < claimData.length, "Invalid index");
        return claimData[_index];
    }

    /**
     * @notice Get the current depth of the game (deepest claim).
     */
    function currentDepth() external view returns (uint256) {
        if (claimData.length == 0) return 0;

        uint256 maxDepth = 0;
        for (uint256 i = 0; i < claimData.length; i++) {
            uint256 depth = _getDepth(claimData[i].position);
            if (depth > maxDepth) {
                maxDepth = depth;
            }
        }
        return maxDepth;
    }

    /**
     * @notice Check if the game can be resolved.
     */
    function canResolve() external view returns (bool) {
        if (status != GameStatus.IN_PROGRESS) return false;
        return block.timestamp >= gameStart + MAX_GAME_DURATION || stepExecuted;
    }

    /**
     * @notice Receive ETH for bonds.
     */
    receive() external payable {}
}

/**
 * @notice Interface for factory callback.
 */
interface IDisputeGameFactory {
    function onGameResolved(uint256 batchIndex, DisputeGame.GameStatus status) external;
}
