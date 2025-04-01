// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICowswapSettlement} from "src/interfaces/ICowswapSettlement.sol";
import {ICirclesBackingFactory} from "src/interfaces/ICirclesBackingFactory.sol";
import {ILBP} from "src/interfaces/ILBP.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {ERC1271Forwarder} from "composable-cow/ERC1271Forwarder.sol";
import {ComposableCoW} from "composable-cow/ComposableCoW.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";

/**
 * @title Circles Backing Instance
 * @notice Instance holds USDC and stable CRC, initiates a Cowswap order to swap USDC into a backing asset.
 *         During Cowswap order execution, a posthook creates a Liquidity Bootstrapping Pool (LBP) with
 *         stable CRC and the backing asset as underlying tokens. This contract holds Balancer Pool Tokens
 *         for one year until they are released by the backer.
 */
contract CirclesBacking is ERC1271Forwarder {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown if the caller of a function is not the Circles Backing Factory.
    error CallerNotFactory();

    /// @notice Thrown if attempting to create an LBP but the order has not yet been filled.
    error OrderNotYetFilled();

    /// @notice Thrown if an LBP is already created when attempting to create another LBP.
    error LBPAlreadyCreated();

    /// @notice Thrown if the backing asset balance is insufficient.
    /// @param received The amount received.
    /// @param required The amount required.
    error BackingAssetBalanceInsufficient(uint256 received, uint256 required);

    /// @notice Thrown if the caller is not the backer.
    error CallerNotBacker();

    /// @notice Thrown if Balancer Pool Tokens are still locked and cannot be released.
    /// @param timestamp The timestamp until which the tokens remain locked.
    error BalancerPoolTokensLockedUntil(uint256 timestamp);

    /// @notice Thrown if the order has already been settled.
    error OrderAlreadySettled();

    /// @notice Thrown if the new order UID is the same as the existing one.
    error OrderUidIsTheSame();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a Cowswap order is created, logging the order UID.
    /// @param orderUid The UID of the newly created order.
    event OrderCreated(bytes orderUid);

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Gnosis Protocol v2 Settlement Contract address.
    ICowswapSettlement public constant COWSWAP_SETTLEMENT =
        ICowswapSettlement(0x9008D19f58AAbD9eD0D60971565AA8510560ab41);

    /// @notice Gnosis Protocol v2 Vault Relayer Contract address.
    address public constant VAULT_RELAY = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    /// @notice LBP token weight 50%.
    uint256 internal constant WEIGHT_50 = 0.5 ether;

    /// @notice Token weight update duration set to 365 days (1 year).
    uint256 internal constant UPDATE_WEIGHT_DURATION = 365 days;

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    /// @notice The Circles Backing Factory.
    ICirclesBackingFactory internal immutable FACTORY;

    /// @notice Address of the circles avatar (the backer).
    address public immutable BACKER;

    /// @notice Address of the backing asset used in the LBP.
    address public immutable BACKING_ASSET;

    /// @notice Address of the stable CRC token used in the LBP.
    address public immutable STABLE_CRC;

    /// @notice Amount of stable CRC tokens to be used in the LBP.
    uint256 public immutable STABLE_CRC_AMOUNT;

    /// @notice Address of the USDC token used for swapping.
    address internal immutable USDC;

    /// @notice Amount of USDC tokens to be used in the swap.
    uint256 internal immutable USDC_AMOUNT;

    /// @notice Cowswap app data represents the `createLBP()` call on this contract as an order posthook.
    bytes32 internal immutable APP_DATA;

    /// @notice Timestamp after which the order is considered to be stuck (not filled).
    uint32 internal immutable ORDER_DEADLINE;

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Stores the current Cowswap order UID.
    bytes public storedOrderUid;

    /// @notice Stores the Composable CoW order hash.
    bytes32 public orderHash;

    /// @notice Minimum backing asset amount the order must buy.
    uint256 public buyAmount;

    /// @notice Address of the created Liquidity Bootstrapping Pool (LBP).
    address public lbp;

    /// @notice Timestamp after which Balancer pool tokens can be claimed by the backer.
    uint256 public balancerPoolTokensUnlockTimestamp;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @dev Initializes the contract, setting up core parameters from the Factory.
     *      Inherits from ERC1271Forwarder to allow Composable CoW order creation.
     */
    constructor() ERC1271Forwarder(ComposableCoW(0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74)) {
        FACTORY = ICirclesBackingFactory(msg.sender);

        // Initialize core values from factory
        (BACKER, BACKING_ASSET, STABLE_CRC, STABLE_CRC_AMOUNT, APP_DATA, USDC, USDC_AMOUNT) =
            FACTORY.backingParameters();

        ORDER_DEADLINE = uint32(block.timestamp + 1 days);
    }

    // -------------------------------------------------------------------------
    // External/Public Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Approves USDC for Cowswap and initiates a ComposableCoW conditional order.
     * @dev Can only be called by the Factory.
     * @param value The minimum backing asset amount that the Cowswap order should buy.
     * @param params The conditional order parameters for ComposableCoW.
     * @param orderUid The Cowswap order UID.
     */
    function initiateCowswapOrder(
        uint256 value,
        IConditionalOrder.ConditionalOrderParams memory params,
        bytes memory orderUid
    ) external {
        if (msg.sender != address(FACTORY)) revert CallerNotFactory();

        // Approve USDC to the Vault Relayer contract
        IERC20(USDC).approve(VAULT_RELAY, USDC_AMOUNT);

        _createOrder(value, orderUid, params);
    }

    /**
     * @notice Resets the Cowswap order if the previous order has not been filled.
     * @dev Reverts if the previous order has already been settled or if the new order UID is the same.
     */
    function resetCowswapOrder() external {
        uint256 filledAmount = COWSWAP_SETTLEMENT.filledAmount(storedOrderUid);
        if (filledAmount != 0) {
            revert OrderAlreadySettled();
        }

        (uint256 value, IConditionalOrder.ConditionalOrderParams memory params, bytes memory orderUid) =
            FACTORY.getConditionalParamsAndOrderUid(address(this), BACKING_ASSET, ORDER_DEADLINE, APP_DATA);

        if (keccak256(storedOrderUid) == keccak256(orderUid)) revert OrderUidIsTheSame();

        // Remove the old order from Composable CoW
        composableCoW.remove(orderHash);

        _createOrder(value, orderUid, params);
    }

    /**
     * @notice Cowswap posthook to create an LBP and provide liquidity.
     * @dev Reverts if LBP is already created, if the order isn't filled but deadline not reached, or if
     *      the backing asset received is insufficient.
     */
    function createLBP() external {
        if (lbp != address(0)) revert LBPAlreadyCreated();

        // Check if the order has been filled on the CowSwap settlement contract
        uint256 filledAmount = COWSWAP_SETTLEMENT.filledAmount(storedOrderUid);
        address backingAsset;
        uint256 backingAmount;

        if (filledAmount != 0) {
            // Use backing asset from the successful swap
            backingAsset = BACKING_ASSET;
            backingAmount = IERC20(backingAsset).balanceOf(address(this));
            if (backingAmount < buyAmount) {
                revert BackingAssetBalanceInsufficient(backingAmount, buyAmount);
            }
        } else if (ORDER_DEADLINE < block.timestamp) {
            // Use USDC to back if the Cowswap order was not executed
            backingAsset = USDC;
            backingAmount = USDC_AMOUNT;
        } else {
            revert OrderNotYetFilled();
        }

        // Remove the filled or expired conditional order from Composable CoW
        composableCoW.remove(orderHash);

        // Create LBP via Factory
        bytes32 poolId;
        IVault.JoinPoolRequest memory request;
        address vault;
        (lbp, poolId, request, vault) = FACTORY.createLBP(STABLE_CRC, STABLE_CRC_AMOUNT, backingAsset, backingAmount);

        // Approve Vault for transferring stable CRC and backing asset
        IERC20(STABLE_CRC).approve(vault, STABLE_CRC_AMOUNT);
        IERC20(backingAsset).approve(vault, backingAmount);

        // Provide liquidity into the LBP
        IVault(vault).joinPool(poolId, address(this), address(this), request);

        // Gradually update weights for one year
        uint256 timestampInYear = block.timestamp + UPDATE_WEIGHT_DURATION;
        ILBP(lbp).updateWeightsGradually(block.timestamp, timestampInYear, _endWeights());

        // Set the BPT unlock timestamp
        balancerPoolTokensUnlockTimestamp = timestampInYear;
    }

    /**
     * @notice Allows the backer to claim Balancer Pool Tokens after the lock period (or global release) has passed.
     * @param receiver The address receiving the Balancer Pool Tokens.
     */
    function releaseBalancerPoolTokens(address receiver) external {
        if (msg.sender != BACKER) revert CallerNotBacker();

        if (FACTORY.releaseTimestamp() > uint32(block.timestamp)) {
            if (balancerPoolTokensUnlockTimestamp > block.timestamp) {
                revert BalancerPoolTokensLockedUntil(balancerPoolTokensUnlockTimestamp);
            }
        }

        // Reset lock timestamp
        balancerPoolTokensUnlockTimestamp = 0;

        // Transfer BPT to the receiver
        uint256 bptAmount = IERC20(lbp).balanceOf(address(this));
        IERC20(lbp).transfer(receiver, bptAmount);

        // Notify factory
        FACTORY.notifyRelease(lbp);
    }

    // -------------------------------------------------------------------------
    // Internal Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Creates (or recreates) an order on Composable CoW.
     * @param value The minimum backing asset amount required.
     * @param orderUid The UID of the new order.
     * @param params The Composable CoW conditional order parameters.
     */
    function _createOrder(uint256 value, bytes memory orderUid, IConditionalOrder.ConditionalOrderParams memory params)
        internal
    {
        // Store the new buy amount
        buyAmount = value;

        // Store the new order UID
        storedOrderUid = orderUid;

        // Calculate and store the conditional order hash
        orderHash = composableCoW.hash(params);

        // Place the conditional order on Composable CoW
        composableCoW.create(params, true);

        // Emit event for the new order UID
        emit OrderCreated(orderUid);
    }

    /**
     * @notice Returns the end weights array for the LBP (both 50%).
     * @return endWeights An array containing end weights for stable CRC and backing asset.
     */
    function _endWeights() internal pure returns (uint256[] memory endWeights) {
        endWeights = new uint256[](2);
        endWeights[0] = WEIGHT_50;
        endWeights[1] = WEIGHT_50;
    }
}
