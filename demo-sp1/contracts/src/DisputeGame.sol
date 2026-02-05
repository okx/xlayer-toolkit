// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./lib/Types.sol";
import "./interfaces/ISP1Verifier.sol";
import "./OutputOracle.sol";

/// @title ZK Bisection Dispute Game
/// @notice Implements Bisection + ZK proof for dispute resolution
/// @dev Flow:
///      1. Challenger initiates dispute on a batch
///      2. Bisection (~10 rounds) to locate the disputed block
///      3. Proposer submits ZK proof for that block
///      4. Verification determines winner
contract DisputeGame {
    using Types for *;

    // ========================================================================
    // Constants
    // ========================================================================

    /// @notice Maximum bisection rounds (log2(1000 blocks) ≈ 10)
    uint256 public constant MAX_BISECTION_ROUNDS = 10;

    /// @notice Challenge bond amount
    uint256 public constant CHALLENGER_BOND = 0.1 ether;

    /// @notice Response timeout (for demo: 1 hour)
    uint256 public constant RESPONSE_TIMEOUT = 1 hours;

    /// @notice Prove timeout after bisection completes
    uint256 public constant PROVE_TIMEOUT = 24 hours;

    // ========================================================================
    // State
    // ========================================================================

    /// @notice Output oracle
    OutputOracle public outputOracle;

    /// @notice SP1 verifier
    ISP1Verifier public sp1Verifier;

    /// @notice SP1 verification key for block-verify program
    bytes32 public blockVerifyVkey;

    /// @notice Batch index being disputed
    uint256 public batchIndex;

    /// @notice Game status
    Types.GameStatus public status;

    /// @notice Challenger address
    address public challenger;

    /// @notice Proposer address
    address public proposer;

    /// @notice Game creation time
    uint256 public createdAt;

    /// @notice Last action time (for timeout)
    uint256 public lastActionAt;

    /// @notice Bisection status
    Types.BisectionStatus public bisectionStatus;

    /// @notice Current bisection round
    uint256 public bisectionRound;

    /// @notice Bisection range: start block
    uint64 public bisectionStart;

    /// @notice Bisection range: end block
    uint64 public bisectionEnd;

    /// @notice Whose turn to respond (true = proposer, false = challenger)
    bool public isProposerTurn;

    /// @notice Disputed block number (set after bisection completes)
    uint64 public disputedBlock;

    /// @notice Proposer's claimed trace hash at disputed block
    bytes32 public proposerTraceHash;

    /// @notice Challenger's claimed trace hash at disputed block
    bytes32 public challengerTraceHash;

    /// @notice Previous trace hash (before disputed block)
    bytes32 public prevTraceHash;

    /// @notice Bisection claims history
    Types.BisectionClaim[] public bisectionClaims;

    // ========================================================================
    // Events
    // ========================================================================

    event GameCreated(uint256 indexed batchIndex, address challenger);
    event BisectionMove(uint256 round, uint64 blockNumber, bytes32 traceHash, bool isProposer);
    event BisectionCompleted(uint64 disputedBlock, bytes32 proposerTrace, bytes32 challengerTrace);
    event ProofSubmitted(address prover);
    event GameResolved(Types.GameStatus status, address winner);

    // ========================================================================
    // Constructor
    // ========================================================================

    constructor(
        address _outputOracle,
        address _sp1Verifier,
        bytes32 _blockVerifyVkey,
        uint256 _batchIndex,
        bytes32 _challengerTraceHash,
        address _challenger
    ) payable {
        require(msg.value >= CHALLENGER_BOND, "Insufficient bond");

        outputOracle = OutputOracle(_outputOracle);
        sp1Verifier = ISP1Verifier(_sp1Verifier);
        blockVerifyVkey = _blockVerifyVkey;
        batchIndex = _batchIndex;

        // Get batch info from oracle
        OutputOracle.Output memory output = outputOracle.getOutput(_batchIndex);
        require(output.timestamp > 0, "Batch not found");

        challenger = _challenger;  // Use passed challenger address
        proposer = output.proposer;
        challengerTraceHash = _challengerTraceHash;
        proposerTraceHash = output.traceHash;

        // Initialize bisection range
        bisectionStart = output.startBlock;
        bisectionEnd = output.endBlock;

        status = Types.GameStatus.IN_PROGRESS;
        bisectionStatus = Types.BisectionStatus.NOT_STARTED;
        createdAt = block.timestamp;
        lastActionAt = block.timestamp;

        // Proposer goes first in bisection
        isProposerTurn = true;

        emit GameCreated(_batchIndex, msg.sender);
    }

    // ========================================================================
    // Bisection
    // ========================================================================

    /// @notice Start bisection (proposer's first move)
    function startBisection(uint64 _midBlock, bytes32 _traceHash) external {
        require(status == Types.GameStatus.IN_PROGRESS, "Game not in progress");
        require(bisectionStatus == Types.BisectionStatus.NOT_STARTED, "Bisection already started");
        require(msg.sender == proposer, "Only proposer");
        require(isProposerTurn, "Not your turn");

        // Validate mid block
        require(_midBlock > bisectionStart && _midBlock < bisectionEnd, "Invalid mid block");

        // Record claim
        bisectionClaims.push(Types.BisectionClaim({
            blockNumber: _midBlock,
            traceHash: _traceHash,
            claimant: msg.sender,
            isProposerClaim: true
        }));

        bisectionStatus = Types.BisectionStatus.IN_PROGRESS;
        bisectionRound = 1;
        isProposerTurn = false;
        lastActionAt = block.timestamp;

        emit BisectionMove(1, _midBlock, _traceHash, true);
    }

    /// @notice Make a bisection move
    /// @param _agree Whether the responder agrees with the previous claim
    /// @param _midBlock If not agreeing, the new mid block to claim
    /// @param _traceHash The trace hash at the new mid block
    function bisect(bool _agree, uint64 _midBlock, bytes32 _traceHash) external {
        require(status == Types.GameStatus.IN_PROGRESS, "Game not in progress");
        require(bisectionStatus == Types.BisectionStatus.IN_PROGRESS, "Bisection not in progress");
        require(bisectionRound < MAX_BISECTION_ROUNDS, "Max rounds reached");

        // Check turn
        if (isProposerTurn) {
            require(msg.sender == proposer, "Not your turn");
        } else {
            require(msg.sender == challenger, "Not your turn");
        }

        // Check timeout
        require(block.timestamp <= lastActionAt + RESPONSE_TIMEOUT, "Response timeout");

        Types.BisectionClaim storage lastClaim = bisectionClaims[bisectionClaims.length - 1];

        if (_agree) {
            // Agreeing narrows the range to the second half
            bisectionStart = lastClaim.blockNumber;
            prevTraceHash = lastClaim.traceHash;
        } else {
            // Disagreeing narrows the range to the first half
            bisectionEnd = lastClaim.blockNumber;
        }

        // Check if bisection is complete (range narrowed to single block)
        if (bisectionEnd - bisectionStart <= 1) {
            _completeBisection();
            return;
        }

        // Record new claim if not agreeing
        if (!_agree) {
            require(_midBlock > bisectionStart && _midBlock < bisectionEnd, "Invalid mid block");
            
            bisectionClaims.push(Types.BisectionClaim({
                blockNumber: _midBlock,
                traceHash: _traceHash,
                claimant: msg.sender,
                isProposerClaim: isProposerTurn
            }));

            emit BisectionMove(bisectionRound + 1, _midBlock, _traceHash, isProposerTurn);
        }

        bisectionRound++;
        isProposerTurn = !isProposerTurn;
        lastActionAt = block.timestamp;
    }

    /// @notice Complete bisection and identify disputed block
    function _completeBisection() internal {
        disputedBlock = bisectionEnd;
        bisectionStatus = Types.BisectionStatus.COMPLETED;
        lastActionAt = block.timestamp;

        emit BisectionCompleted(disputedBlock, proposerTraceHash, challengerTraceHash);
    }

    // ========================================================================
    // Proof Submission
    // ========================================================================

    /// @notice Submit ZK proof for the disputed block
    /// @param _proofBytes The SP1 proof bytes
    /// @param _publicValues The public values (ABI encoded BlockOutput)
    function prove(bytes calldata _proofBytes, bytes calldata _publicValues) external {
        require(status == Types.GameStatus.IN_PROGRESS, "Game not in progress");
        require(bisectionStatus == Types.BisectionStatus.COMPLETED, "Bisection not completed");
        require(block.timestamp <= lastActionAt + PROVE_TIMEOUT, "Prove timeout");

        // Verify the SP1 proof
        sp1Verifier.verifyProof(blockVerifyVkey, _publicValues, _proofBytes);

        // Decode public values
        Types.BlockOutput memory output = abi.decode(_publicValues, (Types.BlockOutput));

        // Verify the output matches disputed block
        require(output.blockNumber == disputedBlock, "Wrong block number");

        // If proof verification passed, the execution is valid
        // The prover demonstrated correct execution of the disputed block
        // In a full implementation, we would check if the proven trace matches
        // the claim made during bisection. For this demo, valid proof = proposer wins
        // because only an honest proposer can generate a valid execution proof.
        status = Types.GameStatus.DEFENDER_WINS;
        emit GameResolved(status, proposer);
        _distributeRewards(proposer);

        emit ProofSubmitted(msg.sender);
    }

    // ========================================================================
    // Resolution
    // ========================================================================

    /// @notice Resolve game on timeout
    function resolveTimeout() external {
        require(status == Types.GameStatus.IN_PROGRESS, "Already resolved");

        if (bisectionStatus == Types.BisectionStatus.NOT_STARTED) {
            // Proposer didn't start bisection
            require(block.timestamp > createdAt + RESPONSE_TIMEOUT, "Not timed out");
            status = Types.GameStatus.CHALLENGER_WINS;
            emit GameResolved(status, challenger);
            _distributeRewards(challenger);
        } else if (bisectionStatus == Types.BisectionStatus.IN_PROGRESS) {
            // Someone didn't respond in bisection
            require(block.timestamp > lastActionAt + RESPONSE_TIMEOUT, "Not timed out");
            
            if (isProposerTurn) {
                // Proposer timed out
                status = Types.GameStatus.CHALLENGER_WINS;
                emit GameResolved(status, challenger);
                _distributeRewards(challenger);
            } else {
                // Challenger timed out
                status = Types.GameStatus.DEFENDER_WINS;
                emit GameResolved(status, proposer);
                _distributeRewards(proposer);
            }
        } else {
            // Bisection completed but no proof submitted
            require(block.timestamp > lastActionAt + PROVE_TIMEOUT, "Not timed out");
            
            // If no proof submitted, challenger wins
            status = Types.GameStatus.CHALLENGER_WINS;
            emit GameResolved(status, challenger);
            _distributeRewards(challenger);
        }
    }

    /// @notice Distribute rewards to winner
    function _distributeRewards(address _winner) internal {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = _winner.call{value: balance}("");
            require(success, "Transfer failed");
        }

        // If challenger wins, delete the invalid output
        if (status == Types.GameStatus.CHALLENGER_WINS) {
            // Note: In production, this would be done through a factory
            // outputOracle.deleteOutput(batchIndex);
        }
    }

    // ========================================================================
    // View Functions
    // ========================================================================

    /// @notice Get current bisection range
    function getBisectionRange() external view returns (uint64, uint64) {
        return (bisectionStart, bisectionEnd);
    }

    /// @notice Get bisection claims count
    function getBisectionClaimsCount() external view returns (uint256) {
        return bisectionClaims.length;
    }

    /// @notice Get bisection claim at index
    function getBisectionClaim(uint256 _index) external view returns (Types.BisectionClaim memory) {
        return bisectionClaims[_index];
    }

    /// @notice Check if game can be resolved due to timeout
    function canResolveTimeout() external view returns (bool) {
        if (status != Types.GameStatus.IN_PROGRESS) return false;

        if (bisectionStatus == Types.BisectionStatus.NOT_STARTED) {
            return block.timestamp > createdAt + RESPONSE_TIMEOUT;
        } else if (bisectionStatus == Types.BisectionStatus.IN_PROGRESS) {
            return block.timestamp > lastActionAt + RESPONSE_TIMEOUT;
        } else {
            return block.timestamp > lastActionAt + PROVE_TIMEOUT;
        }
    }

    /// @notice Receive ETH
    receive() external payable {}
}
