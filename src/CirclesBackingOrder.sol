// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {ICirclesBackingFactory} from "src/interfaces/ICirclesBackingFactory.sol";
import {ICowswapSettlement} from "src/interfaces/ICowswapSettlement.sol";
import {IERC20, GPv2Order, IConditionalOrder, BaseConditionalOrder} from "composable-cow/BaseConditionalOrder.sol";

/**
 * @title CirclesBackingOrder
 * @notice Implements logic for handling a Circles Backing Order.
 * @dev Inherits from BaseConditionalOrder to form a CowSwap-compatible conditional order.
 */
contract CirclesBackingOrder is BaseConditionalOrder {
    /**
     * @notice Holds parameters to construct the order on-chain.
     * @dev This struct is expected to be ABI-encoded and passed as `staticInput` when calling `getTradeableOrder`.
     * @param buyToken The token the order attempts to buy (backing asset).
     * @param buyAmount The desired amount to buy.
     * @param validTo The timestamp until which this order is valid.
     * @param appData Application data represents the Cowswap posthook to execute after the swap.
     */
    struct OrderStaticInput {
        address buyToken;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
    }

    /**
     * @notice The Circles Backing Factory that deploys and manages instances of this contract.
     * @dev Immutable reference to the factory, set at construction.
     */
    ICirclesBackingFactory internal immutable FACTORY;

    /**
     * @notice The token being sold in this order.
     */
    address public immutable SELL_TOKEN;

    /**
     * @notice The amount of `SELL_TOKEN` to sell.
     */
    uint256 public immutable SELL_AMOUNT;

    /**
     * @notice The fee amount for this order (set to 0).
     */
    uint256 public constant FEE_AMOUNT = 0;

    /**
     * @notice The side of the trade (KIND) – here it is a sell order.
     */
    bytes32 public constant KIND = GPv2Order.KIND_SELL;

    /**
     * @notice Indicates if the order is partially fillable. Always `false` (fill-or-kill).
     */
    bool public constant PARTIALLY_FILLABLE = false;

    /**
     * @notice Marker value indicating direct ERC20 balances usage.
     */
    bytes32 public constant BALANCE_ERC20 = GPv2Order.BALANCE_ERC20;

    /**
     * @dev Revert reason if the order creator does not hold enough sell tokens.
     */
    string constant BALANCE_INSUFFICIENT = "balance insufficient";

    /**
     * @dev Revert reason if the order has expired (current time > validTo).
     */
    string constant ORDER_EXPIRED = "order expired";

    /**
     * @dev Revert reason if the requested backing asset is not supported by the factory.
     */
    string constant ASSET_UNSUPPORTED = "asset unsupported";

    /**
     * @notice Deploys a new CirclesBackingOrder.
     * @dev The contract is deployed through the CirclesBackingFactory, which passes itself as `msg.sender`.
     * @param sellToken The token being sold.
     * @param sellAmount The amount of the token to sell.
     */
    constructor(address sellToken, uint256 sellAmount) {
        FACTORY = ICirclesBackingFactory(msg.sender);
        SELL_TOKEN = sellToken;
        SELL_AMOUNT = sellAmount;
    }

    /**
     * @notice Constructs a fully validated, tradeable order if valid conditions are met.
     * @dev Reverts if:
     *  - The `owner` does not have enough `SELL_TOKEN` (BALANCE_INSUFFICIENT).
     *  - The provided backing asset in `staticInput` is not supported (ASSET_UNSUPPORTED).
     *  - The `validTo` timestamp has elapsed (ORDER_EXPIRED).
     * @param owner The contract address creating the order (backing instance).
     * @param staticInput The static input for all discrete orders cut from this conditional order (encoded `OrderStaticInput` struct).
     * @return order The tradeable order for submission to the CoW Protocol API.
     */
    function getTradeableOrder(
        address owner,
        address, /* sender */
        bytes32, /* ctx */
        bytes calldata staticInput,
        bytes calldata /* offchainInput */
    ) public view override returns (GPv2Order.Data memory order) {
        // Check that the owner has a sufficient SELL_TOKEN balance.
        if (IERC20(SELL_TOKEN).balanceOf(owner) < SELL_AMOUNT) {
            revert IConditionalOrder.OrderNotValid(BALANCE_INSUFFICIENT);
        }

        // Decode input parameters needed to build the order.
        OrderStaticInput memory orderStaticInput = abi.decode(staticInput, (OrderStaticInput));

        // Ensure the requested buy token is supported by the factory.
        if (!FACTORY.supportedBackingAssets(orderStaticInput.buyToken)) {
            revert IConditionalOrder.OrderNotValid(ASSET_UNSUPPORTED);
        }

        // Ensure the order is still valid within the specified timestamp.
        if (block.timestamp > orderStaticInput.validTo) {
            revert IConditionalOrder.OrderNotValid(ORDER_EXPIRED);
        }

        // Construct and return the fully validated order.
        order = getOrder(
            owner,
            orderStaticInput.buyToken,
            orderStaticInput.buyAmount,
            orderStaticInput.validTo,
            orderStaticInput.appData
        );
    }

    /**
     * @notice Helper function to build the GPv2Order.Data struct.
     * @dev This is used internally by `getTradeableOrder`.
     * @param owner The address that is the order owner.
     * @param buyToken The token the order intends to buy.
     * @param buyAmount The amount to buy.
     * @param validTo The timestamp when the order becomes invalid.
     * @param appData Application data represents the Cowswap posthook to execute after the swap.
     * @return order The constructed GPv2Order.Data object.
     */
    function getOrder(address owner, address buyToken, uint256 buyAmount, uint32 validTo, bytes32 appData)
        public
        view
        returns (GPv2Order.Data memory order)
    {
        order = GPv2Order.Data({
            sellToken: IERC20(SELL_TOKEN),
            buyToken: IERC20(buyToken),
            receiver: owner,
            sellAmount: SELL_AMOUNT,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: appData,
            feeAmount: FEE_AMOUNT,
            kind: KIND,
            partiallyFillable: PARTIALLY_FILLABLE,
            sellTokenBalance: BALANCE_ERC20,
            buyTokenBalance: BALANCE_ERC20
        });
    }
}
