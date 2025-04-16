// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "src/interfaces/IAggregatorV3Interface.sol";

/**
 * @title MockV3Aggregator
 * @notice A mock implementation of the Chainlink V3 Aggregator for testing purposes
 * @dev Allows for manual manipulation of price data and round information
 */
contract MockPriceFeed is IAggregatorV3Interface {
    uint8 private _decimals;
    string private _description;
    uint256 private _version;

    uint80 private _latestRoundId;
    int256 private _latestAnswer;
    uint256 private _latestStartedAt;
    uint256 private _latestUpdatedAt;
    uint80 private _latestAnsweredInRound;

    // Mapping to store historical round data
    mapping(uint80 => RoundData) private _roundData;

    struct RoundData {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
        bool exists;
    }

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    event NewRound(uint256 indexed roundId, address indexed startedBy, uint256 startedAt);

    /**
     * @notice Initializes the mock aggregator with default values
     * @param __decimals The number of decimals for the returned price answers
     * @param __description A description of what the data feed represents
     * @param __version The version of the aggregator
     * @param __initialAnswer The initial price value to set
     */
    constructor(uint8 __decimals, string memory __description, uint256 __version, int256 __initialAnswer) {
        _decimals = __decimals;
        _description = __description;
        _version = __version;

        // Initialize first round
        _latestRoundId = 1;
        _latestAnswer = __initialAnswer;
        _latestStartedAt = block.timestamp;
        _latestUpdatedAt = block.timestamp;
        _latestAnsweredInRound = 1;

        // Store the first round data
        _roundData[1] = RoundData({
            answer: __initialAnswer,
            startedAt: block.timestamp,
            updatedAt: block.timestamp,
            answeredInRound: 1,
            exists: true
        });

        emit AnswerUpdated(__initialAnswer, 1, block.timestamp);
        emit NewRound(1, msg.sender, block.timestamp);
    }

    /**
     * @notice Returns the number of decimals for the aggregator's value
     * @return The number of decimals
     */
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Returns the description of the aggregator
     * @return The description string
     */
    function description() external view override returns (string memory) {
        return _description;
    }

    /**
     * @notice Returns the version of the aggregator
     * @return The version number
     */
    function version() external view override returns (uint256) {
        return _version;
    }

    /**
     * @notice Returns data from a specific round
     * @param _roundId The round ID to retrieve data from
     * @return roundId The round ID
     * @return answer The price answer for this round
     * @return startedAt Timestamp when the round started
     * @return updatedAt Timestamp when the round was updated
     * @return answeredInRound The round in which this answer was computed
     */
    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        require(_roundData[_roundId].exists, "Round not found");

        RoundData memory data = _roundData[_roundId];
        return (_roundId, data.answer, data.startedAt, data.updatedAt, data.answeredInRound);
    }

    /**
     * @notice Returns the latest round data
     * @return roundId The round ID
     * @return answer The latest price answer
     * @return startedAt Timestamp when the round started
     * @return updatedAt Timestamp when the round was updated
     * @return answeredInRound The round in which this answer was computed
     */
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_latestRoundId, _latestAnswer, _latestStartedAt, _latestUpdatedAt, _latestAnsweredInRound);
    }

    /**
     * @notice Updates the latest answer and creates a new round
     * @param _answer The new price answer
     */
    function updateAnswer(int256 _answer) external {
        uint80 newRoundId = _latestRoundId + 1;

        _latestRoundId = newRoundId;
        _latestAnswer = _answer;
        _latestStartedAt = block.timestamp;
        _latestUpdatedAt = block.timestamp;
        _latestAnsweredInRound = newRoundId;

        // Store the new round data
        _roundData[newRoundId] = RoundData({
            answer: _answer,
            startedAt: block.timestamp,
            updatedAt: block.timestamp,
            answeredInRound: newRoundId,
            exists: true
        });

        emit AnswerUpdated(_answer, newRoundId, block.timestamp);
        emit NewRound(newRoundId, msg.sender, block.timestamp);
    }

    /**
     * @notice Updates the latest round data with full control
     * @param _roundId The round ID to set
     * @param _answer The price answer to set
     * @param _startedAt The timestamp when the round started
     * @param _updatedAt The timestamp when the round was updated
     * @param _answeredInRound The round in which this answer was computed
     */
    function updateRoundData(
        uint80 _roundId,
        int256 _answer,
        uint256 _startedAt,
        uint256 _updatedAt,
        uint80 _answeredInRound
    ) external {
        _latestRoundId = _roundId;
        _latestAnswer = _answer;
        _latestStartedAt = _startedAt;
        _latestUpdatedAt = _updatedAt;
        _latestAnsweredInRound = _answeredInRound;

        // Store or update the round data
        _roundData[_roundId] = RoundData({
            answer: _answer,
            startedAt: _startedAt,
            updatedAt: _updatedAt,
            answeredInRound: _answeredInRound,
            exists: true
        });

        emit AnswerUpdated(_answer, _roundId, _updatedAt);
    }
}
