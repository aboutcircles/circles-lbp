// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {ICowswapSettlement} from "src/interfaces/ICowswapSettlement.sol";
import {IERC20, GPv2Order, IConditionalOrder, BaseConditionalOrder} from "composable-cow/BaseConditionalOrder.sol";
import {ConditionalOrdersUtilsLib as Utils} from "composable-cow/types/ConditionalOrdersUtilsLib.sol";
import {IAggregatorV3Interface} from "src/interfaces/IAggregatorV3Interface.sol";

/**
 * @title Backing Order handler.
 */
contract BackingOrder is BaseConditionalOrder {
    IERC20 public constant USDC = IERC20(0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0);
    /// @notice Amount of USDC.e to use in a swap for backing asset.
    /// @dev set 1USDC for testing, set to 100USDC in prod
    uint256 public constant TRADE_AMOUNT = 1e6;
    

    // returned GPv2Order.Data
    struct DataReturned {
        IERC20 sellToken; // USDC
        IERC20 buyToken; // backing asset is dynamic, should come from (source factory) staticInput or offchainInput (TODO: figure out diff)
        address receiver; // equal owner ibelieve
        uint256 sellAmount; // TRADE_AMOUNT
        uint256 buyAmount; // should be calculated by oracle and utils here, first need to find related oracle
        uint32 validTo; // can be set as 1 day, because if not done in 1 day, then we go with USDC backing
        bytes32 appData; // is dynamic, should come from (source factory) staticInput or offchainInput // SHOULD BE REGISTER BY API CALL /api/v1/app_data/{app_data_hash}
        uint256 feeAmount; // 0
        bytes32 kind; // sell GPv2Order.KIND_SELL
        bool partiallyFillable; // false
        bytes32 sellTokenBalance; // constant GPv2Order.BALANCE_ERC20
        bytes32 buyTokenBalance; // GPv2Order.BALANCE_ERC20
    }


    struct Data {
        IERC20 buyToken; // backing asset is dynamic, should come from (source factory) staticInput or offchainInput (TODO: figure out diff)
        uint256 buyAmount; // should be calculated by oracle and utils here, first need to find related oracle
        uint32 validTo; // can be set as 1 day, because if not done in 1 day, then we go with USDC backing
        bytes32 appData; // is dynamic, should come from (source factory) staticInput or offchainInput // SHOULD BE REGISTER BY API CALL /api/v1/app_data/{app_data_hash}
    }

    function getTradeableOrder(
        address owner,
        address sender,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput
    ) public view override returns (GPv2Order.Data memory order) {
        // Decode the payload into the good after time parameters.
        Data memory data = abi.decode(staticInput, (Data));

        // Don't allow the order to be placed before it becomes valid.
        if (!(block.timestamp >= data.startTime)) {
            revert IConditionalOrder.PollTryAtEpoch(data.startTime, TOO_EARLY);
        }

        // Require that the sell token balance is above the minimum.
        if (!(data.sellToken.balanceOf(owner) >= data.minSellBalance)) {
            revert IConditionalOrder.OrderNotValid(BALANCE_INSUFFICIENT);
        }

        uint256 buyAmount = abi.decode(offchainInput, (uint256));

        // Optionally check the price checker.
        if (data.priceCheckerPayload.length > 0) {
            // Decode the payload into the price checker parameters.
            PriceCheckerPayload memory p = abi.decode(data.priceCheckerPayload, (PriceCheckerPayload));

            // Get the expected out from the price checker.
            uint256 _expectedOut = p.checker.getExpectedOut(data.sellAmount, data.sellToken, data.buyToken, p.payload);

            // Don't allow the order to be placed if the buyAmount is less than the minimum out.
            if (!(buyAmount >= (_expectedOut * (Utils.MAX_BPS - p.allowedSlippage)) / Utils.MAX_BPS)) {
                revert IConditionalOrder.PollTryNextBlock(PRICE_CHECKER_FAILED);
            }
        }

        order = GPv2Order.Data(
            USDC,
            data.buyToken,
            owner,
            TRADE_AMOUNT,
            data.buyAmount,
            data.validTo,
            data.appData,
            0, // use zero fee for limit orders
            GPv2Order.KIND_SELL,
            false,
            GPv2Order.BALANCE_ERC20,
            GPv2Order.BALANCE_ERC20
        );
    }
}