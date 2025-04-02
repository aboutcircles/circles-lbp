// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IValueFactory} from "composable-cow/interfaces/IValueFactory.sol";
import {IAggregatorV3Interface} from "src/interfaces/IAggregatorV3Interface.sol";

contract ValueFactory is IValueFactory {
    struct Oracle {
        IAggregatorV3Interface priceFeed;
        uint8 feedDecimals;
        uint8 tokenDecimals;
    }

    error OnlyBackingFactory();

    event OracleUpdated(address indexed token, address indexed oracle);
    event SlippageUpdated(uint256 indexed newSlippageBPS);

    uint256 internal constant MAX_BPS = 10000;

    address public immutable BACKING_FACTORY;
    // Sell token - USDC.e
    address public immutable SELL_TOKEN;
    uint256 public immutable SELL_AMOUNT;
    uint256 public immutable SELL_UNIT;

    // State

    uint256 public slippageBPS = 500;
    /// @notice Link from buy token to oracle
    mapping(address asset => Oracle) public oracles;

    // Modifiers

    modifier onlyBackingFactory() {
        if (msg.sender != BACKING_FACTORY) revert OnlyBackingFactory();
        _;
    }

    constructor(address sellToken, uint256 sellAmount) {
        BACKING_FACTORY = msg.sender;
        SELL_TOKEN = sellToken;
        SELL_AMOUNT = sellAmount;
        SELL_UNIT = 10 ** IERC20Metadata(sellToken).decimals();
        // USDC.e
        _setOracle(sellToken, address(0x26C31ac71010aF62E6B486D1132E266D6298857D));

        // WBTC
        _setOracle(
            address(0x8e5bBbb09Ed1ebdE8674Cda39A0c169401db4252), address(0x6C1d7e76EF7304a40e8456ce883BC56d3dEA3F7d)
        );
        // WETH
        _setOracle(
            address(0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1), address(0xa767f745331D267c7751297D982b050c93985627)
        );
        // GNO
        _setOracle(
            address(0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb), address(0x22441d81416430A54336aB28765abd31a792Ad37)
        );
        // sDAI
        _setOracle(
            address(0xaf204776c7245bF4147c2612BF6e5972Ee483701), address(0x60F37d5bE3dBe352aD87f043F0BD5bF6cf9BbA78)
        );
    }

    // Admin functions

    /// @dev set price feed address(0) to disable oracle
    /// @dev Caution: Ensure that price feed denominates in USD.
    function setOracle(address token, address priceFeed) external onlyBackingFactory {
        _setOracle(token, priceFeed);
    }

    function setSlippageBPS(uint256 newSlippageBPS) external onlyBackingFactory {
        if (newSlippageBPS > 0 && newSlippageBPS < MAX_BPS) {
            slippageBPS = newSlippageBPS;
            emit SlippageUpdated(newSlippageBPS);
        }
    }

    // View functions

    function getValue(bytes calldata data) external view returns (bytes32 value) {
        address buyToken = abi.decode(data, (address));
        uint256 buyAmount = _defineBuyAmount(buyToken);
        value = bytes32(buyAmount);
    }

    function getValue(address buyToken) external view returns (uint256 buyAmount) {
        buyAmount = _defineBuyAmount(buyToken);
    }

    // Internal functions

    function _setOracle(address _token, address _priceFeed) internal {
        if (_priceFeed == address(0)) {
            delete oracles[_token];
        } else {
            oracles[_token] = Oracle({
                priceFeed: IAggregatorV3Interface(_priceFeed),
                feedDecimals: IAggregatorV3Interface(_priceFeed).decimals(),
                tokenDecimals: IERC20Metadata(_token).decimals()
            });
        }
        emit OracleUpdated(_token, _priceFeed);
    }

    function _defineBuyAmount(address buyToken) internal view returns (uint256 buyAmount) {
        Oracle memory sellOracle = oracles[SELL_TOKEN];
        Oracle memory buyOracle = oracles[buyToken];

        (uint256 basePrice, uint256 sellUpdatedAt) = _getLatestRoundData(sellOracle.priceFeed);
        (uint256 quotePrice, uint256 buyUpdatedAt) = _getLatestRoundData(buyOracle.priceFeed);

        uint256 maxStaleTimestamp = block.timestamp - 1 days;

        // we assume sell token is stable coin
        if (basePrice == 0 || sellUpdatedAt < maxStaleTimestamp) basePrice = 10 ** 8;

        /// @dev Invalid or stale buy price data allows max slippage
        if (quotePrice == 0 || buyUpdatedAt < maxStaleTimestamp) {
            buyAmount = 1;
        } else {
            // Normalize the decimals for basePrice and quotePrice, scaling them to 8 decimals
            // Caution: Ensure that base and quote have the same numeraires (e.g. both are denominated in USD)
            basePrice = _scalePrice(basePrice, sellOracle.feedDecimals, 8);
            quotePrice = _scalePrice(quotePrice, buyOracle.feedDecimals, 8);

            uint256 buyUnit = 10 ** buyOracle.tokenDecimals;
            buyAmount = buyUnit * basePrice * SELL_AMOUNT / (quotePrice * SELL_UNIT);

            buyAmount = buyAmount * (MAX_BPS - slippageBPS) / MAX_BPS;
        }
    }

    function _getLatestRoundData(IAggregatorV3Interface priceFeed)
        internal
        view
        returns (uint256 price, uint256 updatedAt)
    {
        if (address(priceFeed) != address(0)) {
            try priceFeed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt_, uint80) {
                if (answer > 0) price = uint256(answer);
                updatedAt = updatedAt_;
            } catch {}
        }
    }

    /**
     * Given a price returned by a chainlink-like oracle, scale it to the desired amount of decimals
     * @param oraclePrice return by a chainlink-like oracle
     * @param fromDecimals the decimals the oracle returned (e.g. 8 for USDC)
     * @param toDecimals the amount of decimals the price should be scaled to
     */
    function _scalePrice(uint256 oraclePrice, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals < toDecimals) {
            return oraclePrice * 10 ** uint256(toDecimals - fromDecimals);
        } else if (fromDecimals > toDecimals) {
            return oraclePrice / 10 ** uint256(fromDecimals - toDecimals);
        }
        return oraclePrice;
    }
}
