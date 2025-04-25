// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IAggregatorV3Interface} from "src/interfaces/IAggregatorV3Interface.sol";

interface ISDAI {
    function convertToShares(uint256 assets) external view returns (uint256);
}

contract AggregatorSDAI is IAggregatorV3Interface {
    IAggregatorV3Interface public constant DAI_FEED =
        IAggregatorV3Interface(address(0x678df3415fc31947dA4324eC63212874be5a82f8));
    ISDAI public constant SDAI = ISDAI(address(0xaf204776c7245bF4147c2612BF6e5972Ee483701));

    constructor() {}

    function decimals() external pure returns (uint8) {
        return uint8(8);
    }

    function description() external pure returns (string memory) {
        return "SDAI/USD";
    }

    function version() external pure returns (uint256) {
        return uint256(4);
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = DAI_FEED.getRoundData(_roundId);
        answer = _convertToSDAIAnswer(answer);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = DAI_FEED.latestRoundData();
        answer = _convertToSDAIAnswer(answer);
    }

    function _convertToSDAIAnswer(int256 answer) internal view returns (int256) {
        uint256 shares = SDAI.convertToShares(1 ether);
        return int256(uint256(answer) * 1 ether / shares);
    }
}
