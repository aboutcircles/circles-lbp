// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IValueFactory} from "composable-cow/interfaces/IValueFactory.sol";
import {IAggregatorV3Interface} from "src/interfaces/IAggregatorV3Interface.sol";

/**
 * @title ValueFactory
 * @notice ValueFactory manages oracles for specified tokens and provides a calculation of
 *         how much of a "buy token" can be obtained given a "sell token" amount, taking
 *         into account the slippage basis points.
 * @dev This contract expects Chainlink-like oracles that return USD-based quotes. If the
 *      oracle for a buy token returns stale data or no data at all, the calculation
 *      defaults to a small buy amount of 1 unit.
 */
contract ValueFactory is IValueFactory {
    /**
     * @notice Oracle information for a particular token
     * @dev Holds the oracle address, as well as feed decimals and the underlying token decimals.
     *      This is used to properly scale price quotes from the feed to match the token decimals.
     */
    struct Oracle {
        IAggregatorV3Interface priceFeed;
        uint8 feedDecimals;
        uint8 tokenDecimals;
    }

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /**
     * @notice Thrown when a function is called by any address other than BACKING_FACTORY
     */
    error OnlyBackingFactory();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /**
     * @notice Emitted when an oracle for a token is updated
     * @param token The address of the token whose oracle is updated
     * @param oracle The address of the new oracle contract (or zero if being disabled)
     */
    event OracleUpdated(address indexed token, address indexed oracle);

    /**
     * @notice Emitted when the slippage basis points are updated
     * @param newSlippageBPS The new slippage value in basis points
     */
    event SlippageUpdated(uint256 indexed newSlippageBPS);

    // ---------------------------------------------------------------------
    // Constants and Immutable State
    // ---------------------------------------------------------------------

    /**
     * @notice The maximum value for basis points
     */
    uint256 internal constant MAX_BPS = 10000;

    /**
     * @notice Factory address that is authorized to call certain admin functions
     */
    address public immutable BACKING_FACTORY;

    /**
     * @notice Address of the token being sold (e.g. a stablecoin like USDC.e)
     */
    address public immutable SELL_TOKEN;

    /**
     * @notice The total amount of SELL_TOKEN to be sold
     */
    uint256 public immutable SELL_AMOUNT;

    /**
     * @notice The number of decimals for SELL_TOKEN, as a scaled unit (10**decimals)
     */
    uint256 public immutable SELL_UNIT;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /**
     * @notice The current slippage value in basis points
     */
    uint256 public slippageBPS = 500;

    /**
     * @notice Mapping from an asset address to its Oracle configuration
     */
    mapping(address => Oracle) public oracles;

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    /**
     * @dev Ensures only the BACKING_FACTORY can invoke the function
     */
    modifier onlyBackingFactory() {
        if (msg.sender != BACKING_FACTORY) revert OnlyBackingFactory();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /**
     * @notice Deploys the ValueFactory contract
     * @dev Sets initial oracles for a series of tokens (USDC.e, WBTC, WETH, GNO, and sDAI).
     * @param sellToken The token to be sold (e.g. USDC.e)
     * @param sellAmount The total amount of `sellToken` being sold
     */
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

    // ---------------------------------------------------------------------
    // Admin Functions
    // ---------------------------------------------------------------------

    /**
     * @notice Sets or disables the oracle for a given token
     * @dev Only callable by BACKING_FACTORY. Passing address(0) will delete the oracle
     *      configuration for that token. Make sure the oracle is USD-denominated.
     * @param token The token address
     * @param priceFeed The Chainlink-like feed address (or zero to disable)
     */
    function setOracle(address token, address priceFeed) external onlyBackingFactory {
        _setOracle(token, priceFeed);
    }

    /**
     * @notice Updates the slippage basis points
     * @dev Only callable by BACKING_FACTORY. If the new value is outside [0, MAX_BPS],
     *      the function call does nothing.
     * @param newSlippageBPS The new slippage value in basis points
     */
    function setSlippageBPS(uint256 newSlippageBPS) external onlyBackingFactory {
        if (newSlippageBPS > 0 && newSlippageBPS < MAX_BPS) {
            slippageBPS = newSlippageBPS;
            emit SlippageUpdated(newSlippageBPS);
        }
    }

    // ---------------------------------------------------------------------
    // View Functions
    // ---------------------------------------------------------------------

    /**
     * @notice Gets the buy amount for the token passed in calldata as bytes
     * @dev The `data` parameter must encode a single address, which is the buy token
     * @param data Encoded address of the token to buy
     * @return value A bytes32 representation of the computed buy amount
     */
    function getValue(bytes calldata data) external view returns (bytes32 value) {
        address buyToken = abi.decode(data, (address));
        uint256 buyAmount = _defineBuyAmount(buyToken);
        value = bytes32(buyAmount);
    }

    /**
     * @notice Gets the buy amount for the provided token address
     * @param buyToken The token address for which the buy amount is calculated
     * @return buyAmount The calculated buy amount
     */
    function getValue(address buyToken) external view returns (uint256 buyAmount) {
        buyAmount = _defineBuyAmount(buyToken);
    }

    // ---------------------------------------------------------------------
    // Internal Functions
    // ---------------------------------------------------------------------

    /**
     * @notice Sets or deletes the oracle info for a given token
     * @dev If _priceFeed is zero, the oracle is deleted. Otherwise, it is updated with
     *      the feed decimals and token decimals.
     * @param _token The token to set the oracle for
     * @param _priceFeed The Chainlink-like price feed address (or zero to delete)
     */
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

    /**
     * @notice Computes the amount of `buyToken` that can be purchased using the stored
     *         `SELL_AMOUNT` of the `SELL_TOKEN`, factoring in oracle prices and slippage
     * @dev If the buy oracle is stale or invalid, this function defaults to returning 1.
     * @param buyToken The token address to buy
     * @return buyAmount The computed buy amount of `buyToken`
     */
    function _defineBuyAmount(address buyToken) internal view returns (uint256 buyAmount) {
        Oracle memory sellOracle = oracles[SELL_TOKEN];
        Oracle memory buyOracle = oracles[buyToken];

        (uint256 basePrice, uint256 sellUpdatedAt) = _getLatestRoundData(sellOracle.priceFeed);
        (uint256 quotePrice, uint256 buyUpdatedAt) = _getLatestRoundData(buyOracle.priceFeed);

        // Price data older than 1 day is considered stale
        uint256 maxStaleTimestamp = block.timestamp - 1 days;

        // Assume sell token is stable and default to price of 1 (10**8) if stale or zero
        if (basePrice == 0 || sellUpdatedAt < maxStaleTimestamp) {
            basePrice = 10 ** 8;
        }

        // If buy token data is stale or invalid, default to a minimal buy amount
        if (quotePrice == 0 || buyUpdatedAt < maxStaleTimestamp) {
            buyAmount = 1;
        } else {
            // Scale both prices to 8 decimals
            basePrice = _scalePrice(basePrice, sellOracle.feedDecimals, 8);
            quotePrice = _scalePrice(quotePrice, buyOracle.feedDecimals, 8);

            uint256 buyUnit = 10 ** buyOracle.tokenDecimals;

            // Calculate how much buy token you get for SELL_AMOUNT of sell token
            buyAmount = (buyUnit * basePrice * SELL_AMOUNT) / (quotePrice * SELL_UNIT);

            // Apply slippage
            buyAmount = (buyAmount * (MAX_BPS - slippageBPS)) / MAX_BPS;
        }
    }

    /**
     * @notice Retrieves the latest price data from the specified price feed
     * @dev Returns (0,0) if the feed is invalid or fails. Ignores other returned fields
     * @param priceFeed The Chainlink-like price feed
     * @return price The uint256 representation of the price
     * @return updatedAt The timestamp of the latest round data
     */
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
     * @notice Scales a price from `fromDecimals` decimals to `toDecimals` decimals
     * @param oraclePrice The price returned by a Chainlink-like oracle
     * @param fromDecimals The decimals the oracle returned (commonly 8 for USD prices)
     * @param toDecimals The desired decimals to scale the price to
     * @return The scaled price
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
