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
 * @title Circles Backing Instance.
 * @notice Instance holds USDC and stable CRC, initiates Cowswap order to swap USDC into backing asset.
 *         During Cowswap order execution posthook creates Liquidity Bootstraping Pool with stable CRC
 *         and backing asset as underlying tokens. Instance holds Balancer Pool Tokens one year until
 *         they are released by backer.
 */
contract CirclesBacking is ERC1271Forwarder {
    // Errors
    /// Method is allowed to be called only by Factory.
    error OnlyFactory();
    /// Function must be called only by Cowswap posthook.
    error OrderNotFilledYet();
    /// LBP is already created.
    error AlreadyCreated();
    /// Cowswap solver must transfer the swap result before calling posthook.
    error InsufficientBackingAssetBalance();
    /// Unauthorized access.
    error NotBacker();
    /// Balancer Pool Tokens are still locked until `timestamp`.
    error TokensLockedUntilTimestamp(uint256 timestamp);

    error OrderAlreadySettled();

    // Events
    /// @notice Emitted when Cowswap order is created, logging order uid.
    event OrderCreated(bytes orderUid);

    // Constants
    /// @notice Gnosis Protocol v2 Settlement Contract.
    ICowswapSettlement public constant COWSWAP_SETTLEMENT =
        ICowswapSettlement(address(0x9008D19f58AAbD9eD0D60971565AA8510560ab41));
    /// @notice Gnosis Protocol v2 Vault Relayer Contract.
    address public constant VAULT_RELAY = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
    /// @dev LBP token weight 50%.
    uint256 internal constant WEIGHT_50 = 0.5 ether;
    /// @dev Update weight duration and lbp lock period is set to 1 year.
    uint256 internal constant UPDATE_WEIGHT_DURATION = 365 days;

    // Immutables
    /// @dev Circles Backing Factory.
    ICirclesBackingFactory internal immutable FACTORY;
    /// @notice Address of circles avatar, which has backed his personal circles.
    address public immutable BACKER;
    /// @notice Address of supported backing asset, which is used as underlying asset in lbp.
    address public immutable BACKING_ASSET;
    /// @notice Address of ERC20 stable Circles version (InflationaryCircles), which is used as underlying asset in lbp.
    address public immutable STABLE_CRC;
    /// @notice Amount of ERC20 stable Circles, which is used in lbp.
    uint256 public immutable STABLE_CRC_AMOUNT;
    /// @dev USDC.e contract address.
    address internal immutable USDC;
    /// @dev Amount of USDC.e to use.
    uint256 internal immutable USDC_AMOUNT;
    /// @dev Cowswap app data.
    bytes32 internal immutable APP_DATA;
    /// @dev Timestamp, when cowswap order is considered to be stuck.
    uint32 internal immutable ORDER_DEADLINE;

    // Storage
    /// @notice Address of created Liquidity Bootstrapping Pool, which represents backing liquidity.
    address public lbp;
    /// @notice Timestamp, when locked balancer pool tokens are allowed to be claimed by backer.
    uint256 public balancerPoolTokensUnlockTimestamp;

    /// @notice Composable Cow order hash.
    bytes public storedOrderUid;
    bytes32 public orderHash;
    uint256 public buyAmount;

    constructor() ERC1271Forwarder(ComposableCoW(address(0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74))) {
        FACTORY = ICirclesBackingFactory(msg.sender);
        // init core values
        (BACKER, BACKING_ASSET, STABLE_CRC, STABLE_CRC_AMOUNT, APP_DATA, USDC, USDC_AMOUNT) =
            FACTORY.backingParameters();
        ORDER_DEADLINE = uint32(block.timestamp + 1 days);
    }

    // Backing logic

    /// @notice Approves Cowswap to spend USDC and initiates composable-cow conditional order.
    function initiateCowswapOrder(
        uint256 value,
        IConditionalOrder.ConditionalOrderParams memory params,
        bytes memory orderUid
    ) external {
        if (msg.sender != address(FACTORY)) revert OnlyFactory();
        // Approve USDC to Vault Relay contract
        IERC20(USDC).approve(VAULT_RELAY, USDC_AMOUNT);

        // store buy amount
        buyAmount = value;
        // store order uid
        storedOrderUid = orderUid;

        // Store the conditional order hash
        orderHash = composableCoW.hash(params);
        // Place the conditional order on composable cow
        composableCoW.create(params, true);

        emit OrderCreated(storedOrderUid);
    }
/*    
    function resetOrder() external {
        uint256 filledAmount = COWSWAP_SETTLEMENT.filledAmount(storedOrderUid);
        if (filledAmount != 0) {
            revert OrderAlreadySettled();
        }
        // TODO: remove uid from settlement
        composableCoW.remove(orderHash);

        (uint256 value, IConditionalOrder.ConditionalOrderParams memory params, bytes memory orderUid) = FACTORY.getConditionalParamsAndOrderUid(
            address(this),
            BACKING_ASSET,
            ORDER_DEADLINE,
            APP_DATA
        );

        // store new buy amount
        buyAmount = value;
        // store new order uid
        storedOrderUid = orderUid;

        // Store the conditional order hash
        orderHash = composableCoW.hash(params);
        // Place the conditional order on composable cow
        composableCoW.create(params, true);

        emit OrderCreated(storedOrderUid);
    }
*/    
    /// @notice Method, which should be used as Cowswap posthook interaction.
    ///         Creates preconfigured LBP and provides liquidity to it.

    function createLBP() external {
        if (lbp != address(0)) revert AlreadyCreated();
        // Check if the order has been filled on the CowSwap settlement contract
        uint256 filledAmount = COWSWAP_SETTLEMENT.filledAmount(storedOrderUid);
        address backingAsset;
        uint256 backingAmount;

        if (filledAmount != 0) {
            // use picked backing asset in case cowswap order is executed
            backingAsset = BACKING_ASSET;
            backingAmount = IERC20(backingAsset).balanceOf(address(this));
            if (backingAmount < buyAmount) revert InsufficientBackingAssetBalance();
        } else if (ORDER_DEADLINE < block.timestamp) {
            // use USDC to back in case cowswap order is not executed
            backingAsset = USDC;
            backingAmount = USDC_AMOUNT;
        } else {
            revert OrderNotFilledYet();
        }

        // composableCoW.remove(orderHash);

        // Create LBP
        bytes32 poolId;
        IVault.JoinPoolRequest memory request;
        address vault;
        (lbp, poolId, request, vault) = FACTORY.createLBP(STABLE_CRC, STABLE_CRC_AMOUNT, backingAsset, backingAmount);

        // approve vault
        IERC20(STABLE_CRC).approve(vault, STABLE_CRC_AMOUNT);
        IERC20(backingAsset).approve(vault, backingAmount);

        // provide liquidity into lbp
        IVault(vault).joinPool(
            poolId,
            address(this), // sender
            address(this), // recipient
            request
        );

        // update weight gradually
        uint256 timestampInYear = block.timestamp + UPDATE_WEIGHT_DURATION;
        ILBP(lbp).updateWeightsGradually(block.timestamp, timestampInYear, _endWeights());

        // set bpt unlock
        balancerPoolTokensUnlockTimestamp = timestampInYear;
    }

    // Balancer pool tokens

    /// @notice Method allows backer to claim balancer pool tokens after lock period or in case of global release.
    /// @param receiver Address, which will receive balancer pool tokens.
    function releaseBalancerPoolTokens(address receiver) external {
        if (msg.sender != BACKER) revert NotBacker();

        if (FACTORY.releaseTimestamp() > uint32(block.timestamp)) {
            if (balancerPoolTokensUnlockTimestamp > block.timestamp) {
                revert TokensLockedUntilTimestamp(balancerPoolTokensUnlockTimestamp);
            }
        }
        // zeroed timestamp
        balancerPoolTokensUnlockTimestamp = 0;

        uint256 bptAmount = IERC20(lbp).balanceOf(address(this));
        IERC20(lbp).transfer(receiver, bptAmount);

        // emit event on factory lvl
        FACTORY.notifyRelease(lbp);
    }

    // Internal functions

    function _endWeights() internal pure returns (uint256[] memory endWeights) {
        endWeights = new uint256[](2);
        endWeights[0] = WEIGHT_50;
        endWeights[1] = WEIGHT_50;
    }
}
