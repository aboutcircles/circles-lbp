// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IValueFactory} from "composable-cow/interfaces/IValueFactory.sol";
import {IAggregatorV3Interface} from "src/interfaces/IAggregatorV3Interface.sol";
import {ConditionalOrdersUtilsLib as Utils} from "composable-cow/types/ConditionalOrdersUtilsLib.sol";

contract ValueFactory {
    struct Oracle {
        IAggregatorV3Interface priceFeed;
        uint8 tokenDecimals;
    }

    uint256 public immutable SELL_AMOUNT;
    /// @notice Order sell token unit.
    uint256 public immutable SELL_UNIT;
    // USDC
    IAggregatorV3Interface public constant SELL_PRICE_FEED =
        IAggregatorV3Interface(address(0x26C31ac71010aF62E6B486D1132E266D6298857D));

    // State
    /// @notice Link from buy token to oracle
    /// TODO: implement logic to set by factory feeds
    mapping(address asset => Oracle) public oracles;

    constructor(uint256 sellAmount, uint256 sellTokenUnit) {
        SELL_AMOUNT = sellAmount;
        SELL_UNIT = sellTokenUnit;
        // WBTC
        oracles[address(0x8e5bBbb09Ed1ebdE8674Cda39A0c169401db4252)] = Oracle({
            priceFeed: IAggregatorV3Interface(address(0x6C1d7e76EF7304a40e8456ce883BC56d3dEA3F7d)),
            tokenDecimals: uint8(8)
        });

        // WETH
        oracles[address(0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1)] = Oracle({
            priceFeed: IAggregatorV3Interface(address(0xa767f745331D267c7751297D982b050c93985627)),
            tokenDecimals: uint8(18)
        });

        // GNO
        oracles[address(0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb)] = Oracle({
            priceFeed: IAggregatorV3Interface(address(0x22441d81416430A54336aB28765abd31a792Ad37)),
            tokenDecimals: uint8(18)
        });
        // sDAI price feed doesn't exist, so we are using DAI price feed and sDAI convertToShares function
        // function convertToShares(uint256 assets) public view virtual returns (uint256);
        // simplest to support same interface, would be to deploy priceFeed, which is doing this logic
        // sDAI: address(0xaf204776c7245bF4147c2612BF6e5972Ee483701)
        // DAI price feed: 0x678df3415fc31947dA4324eC63212874be5a82f8
        // priceFeeds[address(0xaf204776c7245bF4147c2612BF6e5972Ee483701)] = deployedAdapter; // sDAI
    }

    function getValue(bytes calldata data) external view returns (bytes32 value) {
        address buyToken = abi.decode(data, (address));
        (uint256 buyAmount, uint256 sellUpdatedAt, uint256 buyUpdatedAt) = defineBuyAmount(buyToken);
        value = bytes32(buyAmount);
    }

    function getValue(address buyToken) external view returns (uint256 buyAmount) {
        (buyAmount,,) = defineBuyAmount(buyToken);
    }

    function defineBuyAmount(address buyToken)
        internal
        view
        returns (uint256 buyAmount, uint256 sellUpdatedAt, uint256 buyUpdatedAt)
    {
        Oracle memory buyOracle = oracles[buyToken];

        int256 basePrice;
        int256 quotePrice;
        (, basePrice,, sellUpdatedAt,) = SELL_PRICE_FEED.latestRoundData();
        (, quotePrice,, buyUpdatedAt,) = buyOracle.priceFeed.latestRoundData();

        /// @dev Guard against invalid price data
        if (!(basePrice > 0 && quotePrice > 0)) {
            buyAmount = 1;
        } else {
            // Normalize the decimals for basePrice and quotePrice, scaling them to 18 decimals
            // Caution: Ensure that base and quote have the same numeraires (e.g. both are denominated in USD)
            //basePrice = Utils.scalePrice(basePrice, sellPriceFeed.decimals(), 18);
            //quotePrice = Utils.scalePrice(quotePrice, buyPriceFeed.decimals(), 18);
            uint256 buyUnit = 10 ** buyOracle.tokenDecimals;
            buyAmount = buyUnit * uint256(basePrice) * SELL_AMOUNT / (uint256(quotePrice) * SELL_UNIT);

            buyAmount = buyAmount * 95 / 100; // 5% slippage
        }
    }
}
