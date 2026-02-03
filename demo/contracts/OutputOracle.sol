// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title OutputOracle
 * @notice Stores state commitments submitted by Proposer.
 * @dev Proposer submits both incremental StateHash and MPT Root.
 *      MPT Root is used for Cannon fault proof challenges.
 */
contract OutputOracle {
    /// @notice Represents an output proposal
    struct OutputProposal {
        bytes32 stateHash;      // Incremental state hash
        bytes32 mptRoot;        // MPT root for fault proofs
        uint128 timestamp;      // Submission timestamp
        uint128 l2BlockNumber;  // L2 block number this output covers
    }

    /// @notice Event emitted when an output is proposed
    event OutputProposed(
        uint256 indexed batchIndex,
        bytes32 stateHash,
        bytes32 mptRoot,
        uint256 l2BlockNumber,
        address indexed proposer,
        uint256 timestamp
    );

    /// @notice Event emitted when an output is deleted (due to successful challenge)
    event OutputDeleted(
        uint256 indexed batchIndex,
        bytes32 stateHash,
        bytes32 mptRoot
    );

    /// @notice Mapping of batch index to output proposal
    mapping(uint256 => OutputProposal) public outputs;

    /// @notice The next output index
    uint256 public nextOutputIndex;

    /// @notice The latest finalized output index
    uint256 public latestFinalizedIndex;

    /// @notice Challenge window in seconds (default: 7 days)
    uint256 public challengeWindow;

    /// @notice The authorized proposer address
    address public proposer;

    /// @notice The dispute game factory address
    address public disputeGameFactory;

    /// @notice Owner address
    address public owner;

    modifier onlyProposer() {
        require(msg.sender == proposer, "Only proposer can submit");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyDisputeGame() {
        require(msg.sender == disputeGameFactory, "Only dispute game");
        _;
    }

    constructor(
        address _proposer,
        address _disputeGameFactory,
        uint256 _challengeWindow
    ) {
        owner = msg.sender;
        proposer = _proposer;
        disputeGameFactory = _disputeGameFactory;
        challengeWindow = _challengeWindow;
        nextOutputIndex = 0;
        latestFinalizedIndex = 0;
    }

    /**
     * @notice Submit a new output proposal
     * @param stateHash The incremental state hash
     * @param mptRoot The MPT root for fault proofs
     * @param l2BlockNumber The L2 block number
     */
    function proposeOutput(
        bytes32 stateHash,
        bytes32 mptRoot,
        uint256 l2BlockNumber
    ) external onlyProposer {
        require(stateHash != bytes32(0), "Invalid state hash");
        require(mptRoot != bytes32(0), "Invalid MPT root");

        uint256 batchIndex = nextOutputIndex;

        outputs[batchIndex] = OutputProposal({
            stateHash: stateHash,
            mptRoot: mptRoot,
            timestamp: uint128(block.timestamp),
            l2BlockNumber: uint128(l2BlockNumber)
        });

        nextOutputIndex++;

        emit OutputProposed(
            batchIndex,
            stateHash,
            mptRoot,
            l2BlockNumber,
            msg.sender,
            block.timestamp
        );
    }

    /**
     * @notice Delete an output due to successful challenge
     * @param batchIndex The batch index to delete
     */
    function deleteOutput(uint256 batchIndex) external onlyDisputeGame {
        OutputProposal storage output = outputs[batchIndex];
        require(output.timestamp > 0, "Output not found");

        bytes32 stateHash = output.stateHash;
        bytes32 mptRoot = output.mptRoot;

        delete outputs[batchIndex];

        emit OutputDeleted(batchIndex, stateHash, mptRoot);
    }

    /**
     * @notice Get an output proposal
     * @param batchIndex The batch index
     */
    function getOutput(uint256 batchIndex)
        external
        view
        returns (OutputProposal memory)
    {
        return outputs[batchIndex];
    }

    /**
     * @notice Check if an output is finalized (past challenge window)
     * @param batchIndex The batch index
     */
    function isFinalized(uint256 batchIndex) external view returns (bool) {
        OutputProposal storage output = outputs[batchIndex];
        if (output.timestamp == 0) return false;
        return block.timestamp >= output.timestamp + challengeWindow;
    }

    /**
     * @notice Get the MPT root for a batch (used by dispute games)
     * @param batchIndex The batch index
     */
    function getMPTRoot(uint256 batchIndex) external view returns (bytes32) {
        return outputs[batchIndex].mptRoot;
    }

    /**
     * @notice Finalize outputs that are past the challenge window
     */
    function finalizeOutputs() external {
        for (uint256 i = latestFinalizedIndex; i < nextOutputIndex; i++) {
            OutputProposal storage output = outputs[i];
            if (output.timestamp == 0) continue;
            if (block.timestamp < output.timestamp + challengeWindow) break;
            latestFinalizedIndex = i + 1;
        }
    }

    /**
     * @notice Update proposer address
     */
    function setProposer(address _proposer) external onlyOwner {
        proposer = _proposer;
    }

    /**
     * @notice Update dispute game factory address
     */
    function setDisputeGameFactory(address _factory) external onlyOwner {
        disputeGameFactory = _factory;
    }

    /**
     * @notice Update challenge window
     */
    function setChallengeWindow(uint256 _window) external onlyOwner {
        challengeWindow = _window;
    }
}
