// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {ICirclesBackingFactory} from "src/interfaces/ICirclesBackingFactory.sol";
import {ICowswapSettlement} from "src/interfaces/ICowswapSettlement.sol";
import {IERC20, GPv2Order, IConditionalOrder, BaseConditionalOrder} from "composable-cow/BaseConditionalOrder.sol";

/**
 * @title Circles Backing Order handler.
 */
contract CirclesBackingOrder is BaseConditionalOrder {
    // static input
    struct OrderStaticInput {
        address buyToken; // backingAsset
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
    }

    /*
    bytes32 internal constant TYPE_HASH =
        hex"d5a25ba2e97094ad7d83dc28a6572da797d6b3e7fc6663bd93efb789fc17e489";
    */

    /// @dev Circles Backing Factory.
    ICirclesBackingFactory internal immutable FACTORY;
    /// @notice Order sell token contract address.
    address public immutable SELL_TOKEN;
    /// @notice Order amount to sell.
    uint256 public immutable SELL_AMOUNT;
    /// @notice Order fee amount.
    uint256 public constant FEE_AMOUNT = 0;
    /// @notice Order kind: sell.
    bytes32 public constant KIND = GPv2Order.KIND_SELL;
    /// @notice Order type: fill or kill.
    bool public constant PARTIALLY_FILLABLE = false;
    /// @notice The TokenBalance marker value for using direct ERC20 balances.
    bytes32 public constant BALANCE_ERC20 = GPv2Order.BALANCE_ERC20;

    /// @dev If the sell token balance is below the required.
    string constant BALANCE_INSUFFICIENT = "balance insufficient";
    /// @dev If the order expired.
    string constant ORDER_EXPIRED = "order expired";
    /// @dev If the backing asset is not supported.
    string constant ASSET_UNSUPPORTED = "asset unsupported";

    // Constructor
    constructor(address sellToken, uint256 sellAmount) {
        FACTORY = ICirclesBackingFactory(msg.sender);
        SELL_TOKEN = sellToken;
        SELL_AMOUNT = sellAmount;
    }

    // TODO: use FACTORY.supportedBackingAssets in verify buyToken is supported

    function getTradeableOrder(
        address owner, // instance
        address, // sender
        bytes32, // ctx
        bytes calldata staticInput,
        bytes calldata /* offchainInput */
    ) public view override returns (GPv2Order.Data memory order) {
        // Require that the sell token balance is present.
        if (IERC20(SELL_TOKEN).balanceOf(owner) < SELL_AMOUNT) {
            revert IConditionalOrder.OrderNotValid(BALANCE_INSUFFICIENT);
        }

        // Decode the staticInput into the OrderStaticInput parameters.
        OrderStaticInput memory orderStaticInput = abi.decode(staticInput, (OrderStaticInput));

        if (!FACTORY.supportedBackingAssets(orderStaticInput.buyToken)) {
            revert IConditionalOrder.OrderNotValid(ASSET_UNSUPPORTED);
        }

        // Don't allow the order to be placed after valid to has expired.
        if (block.timestamp > orderStaticInput.validTo) {
            revert IConditionalOrder.OrderNotValid(ORDER_EXPIRED);
        }

        order = getOrder(
            owner,
            orderStaticInput.buyToken,
            orderStaticInput.buyAmount,
            orderStaticInput.validTo,
            orderStaticInput.appData
        );
    }

    function getOrder(address owner, address buyToken, uint256 buyAmount, uint32 validTo, bytes32 appData)
        public
        view
        returns (GPv2Order.Data memory order)
    {
        order = GPv2Order.Data(
            IERC20(SELL_TOKEN),
            IERC20(buyToken),
            owner,
            SELL_AMOUNT,
            buyAmount,
            validTo,
            appData,
            FEE_AMOUNT,
            KIND,
            PARTIALLY_FILLABLE,
            BALANCE_ERC20,
            BALANCE_ERC20
        );
    }
}
