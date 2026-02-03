// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BatchInbox
 * @notice Receives transaction data from Batcher for data availability.
 * @dev Batcher only submits transaction data (or hash), not MPT root.
 *      MPT root is submitted separately by Proposer to OutputOracle.
 */
contract BatchInbox {
    /// @notice Event emitted when batch data is submitted
    event BatchDataSubmitted(
        uint256 indexed batchIndex,
        bytes32 txDataHash,
        address indexed submitter,
        uint256 timestamp
    );

    /// @notice Mapping of batch index to tx data hash
    mapping(uint256 => bytes32) public batchTxDataHash;

    /// @notice Mapping of batch index to submission timestamp
    mapping(uint256 => uint256) public batchTimestamp;

    /// @notice The next batch index to be submitted
    uint256 public nextBatchIndex;

    /// @notice The authorized batcher address
    address public batcher;

    /// @notice Owner address for admin functions
    address public owner;

    modifier onlyBatcher() {
        require(msg.sender == batcher, "Only batcher can submit");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor(address _batcher) {
        owner = msg.sender;
        batcher = _batcher;
        nextBatchIndex = 0;
    }

    /**
     * @notice Submit batch transaction data hash
     * @param batchIndex The batch index
     * @param txDataHash Hash of the transaction data
     */
    function submitBatchData(
        uint256 batchIndex,
        bytes32 txDataHash
    ) external onlyBatcher {
        require(batchIndex == nextBatchIndex, "Invalid batch index");
        require(txDataHash != bytes32(0), "Invalid tx data hash");

        batchTxDataHash[batchIndex] = txDataHash;
        batchTimestamp[batchIndex] = block.timestamp;
        nextBatchIndex++;

        emit BatchDataSubmitted(batchIndex, txDataHash, msg.sender, block.timestamp);
    }

    /**
     * @notice Get batch info
     * @param batchIndex The batch index
     * @return txDataHash The transaction data hash
     * @return timestamp The submission timestamp
     */
    function getBatchInfo(uint256 batchIndex)
        external
        view
        returns (bytes32 txDataHash, uint256 timestamp)
    {
        return (batchTxDataHash[batchIndex], batchTimestamp[batchIndex]);
    }

    /**
     * @notice Check if a batch has been submitted
     * @param batchIndex The batch index
     */
    function isBatchSubmitted(uint256 batchIndex) external view returns (bool) {
        return batchTimestamp[batchIndex] > 0;
    }

    /**
     * @notice Update batcher address
     * @param _batcher New batcher address
     */
    function setBatcher(address _batcher) external onlyOwner {
        batcher = _batcher;
    }
}
