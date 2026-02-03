// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DisputeGame.sol";
import "./OutputOracle.sol";
import "./MIPS.sol";

/**
 * @title DisputeGameFactory
 * @notice Factory contract for creating dispute games.
 * @dev Creates dispute game instances for challenging output proposals.
 */
contract DisputeGameFactory {
    /// @notice Game information stored in the factory
    struct GameInfo {
        address gameAddress;     // Address of the dispute game contract
        uint256 batchIndex;      // Batch index being disputed
        bytes32 rootClaim;       // The challenger's claimed root
        uint256 createdAt;       // Timestamp when game was created
        address challenger;      // Address that created the game
    }

    /// @notice Event emitted when a dispute game is created
    event DisputeGameCreated(
        uint256 indexed gameIndex,
        address indexed gameAddress,
        uint256 indexed batchIndex,
        bytes32 rootClaim,
        address challenger
    );

    /// @notice Event emitted when a dispute game is resolved
    event DisputeGameResolved(
        uint256 indexed gameIndex,
        address indexed gameAddress,
        DisputeGame.GameStatus status
    );

    /// @notice The output oracle contract
    OutputOracle public outputOracle;

    /// @notice The MIPS VM contract
    MIPS public mipsVM;

    /// @notice All games created by this factory
    GameInfo[] public games;

    /// @notice Mapping of batch index to active game index
    mapping(uint256 => uint256) public activeGames;

    /// @notice Check if a batch has an active dispute
    mapping(uint256 => bool) public hasActiveDispute;

    /// @notice Bond required to create a game
    uint256 public constant CREATE_GAME_BOND = 0.1 ether;

    /// @notice Owner address
    address public owner;

    /// @notice Maximum game depth (total bisection steps)
    uint256 public constant MAX_GAME_DEPTH = 64;

    /// @notice Split depth (output bisection vs execution trace bisection)
    uint256 public constant SPLIT_DEPTH = 30;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor(address _outputOracle, address _mipsVM) {
        owner = msg.sender;
        outputOracle = OutputOracle(_outputOracle);
        mipsVM = MIPS(_mipsVM);
    }

    /**
     * @notice Create a new dispute game for a batch.
     * @param _batchIndex The batch index to dispute.
     * @param _rootClaim The challenger's claimed root (should differ from proposer's).
     * @return gameAddr The address of the created game.
     */
    function createGame(
        uint256 _batchIndex,
        bytes32 _rootClaim
    ) external payable returns (address gameAddr) {
        require(msg.value >= CREATE_GAME_BOND, "Insufficient bond");
        require(!hasActiveDispute[_batchIndex], "Batch already disputed");

        // Verify the batch exists and is not finalized
        OutputOracle.OutputProposal memory output = outputOracle.getOutput(_batchIndex);
        require(output.timestamp > 0, "Output not found");
        require(!outputOracle.isFinalized(_batchIndex), "Output already finalized");

        // Create the dispute game
        DisputeGame game = new DisputeGame(
            address(outputOracle),
            address(mipsVM),
            _batchIndex,
            _rootClaim
        );
        gameAddr = address(game);

        // Store game info
        uint256 gameIndex = games.length;
        games.push(GameInfo({
            gameAddress: gameAddr,
            batchIndex: _batchIndex,
            rootClaim: _rootClaim,
            createdAt: block.timestamp,
            challenger: msg.sender
        }));

        // Mark batch as having active dispute
        hasActiveDispute[_batchIndex] = true;
        activeGames[_batchIndex] = gameIndex;

        emit DisputeGameCreated(
            gameIndex,
            gameAddr,
            _batchIndex,
            _rootClaim,
            msg.sender
        );

        // Forward bond to game contract
        (bool success, ) = gameAddr.call{value: msg.value}("");
        require(success, "Bond transfer failed");
    }

    /**
     * @notice Get the number of games created.
     */
    function gameCount() external view returns (uint256) {
        return games.length;
    }

    /**
     * @notice Get game info by index.
     */
    function getGame(uint256 _index) external view returns (GameInfo memory) {
        require(_index < games.length, "Invalid index");
        return games[_index];
    }

    /**
     * @notice Get the active game for a batch.
     */
    function getActiveGame(uint256 _batchIndex) external view returns (address) {
        if (!hasActiveDispute[_batchIndex]) {
            return address(0);
        }
        return games[activeGames[_batchIndex]].gameAddress;
    }

    /**
     * @notice Called by dispute game when resolved.
     */
    function onGameResolved(uint256 _batchIndex, DisputeGame.GameStatus _status) external {
        require(hasActiveDispute[_batchIndex], "No active dispute");
        require(games[activeGames[_batchIndex]].gameAddress == msg.sender, "Not active game");

        hasActiveDispute[_batchIndex] = false;

        emit DisputeGameResolved(
            activeGames[_batchIndex],
            msg.sender,
            _status
        );
    }

    /**
     * @notice Update the output oracle address.
     */
    function setOutputOracle(address _outputOracle) external onlyOwner {
        outputOracle = OutputOracle(_outputOracle);
    }

    /**
     * @notice Update the MIPS VM address.
     */
    function setMIPSVM(address _mipsVM) external onlyOwner {
        mipsVM = MIPS(_mipsVM);
    }

    /**
     * @notice Receive ETH from resolved games.
     */
    receive() external payable {}
}
