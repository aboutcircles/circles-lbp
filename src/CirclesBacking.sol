// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICowswapSettlement} from "src/interfaces/ICowswapSettlement.sol";
import {IFactory} from "src/interfaces/IFactory.sol";
import {ILBP} from "src/interfaces/ILBP.sol";
import {IVault} from "src/interfaces/IVault.sol";

contract CirclesBacking {
    // Errors
    /// Method is allowed to be called only by Factory.
    error OnlyFactory();
    /// LBP is already created.
    error AlreadyCreated();
    /// Cowswap solver must transfer the swap result before calling posthook.
    error InsufficientBackingAssetBalance();
    /// Unauthorized access.
    error NotBacker();
    /// Balancer Pool Tokens are still locked until `timestamp`.
    error TokensLockedUntilTimestamp(uint256 timestamp);

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
    IFactory internal immutable FACTORY;
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

    // Storage
    /// @notice Address of created Liquidity Bootstrapping Pool, which represents backing liquidity.
    address public lbp;
    /// @notice Timestamp, when locked balancer pool tokens are allowed to be claimed by backer.
    uint256 public balancerPoolTokensUnlockTimestamp;
    /// @notice Cowswap order uid.
    bytes public storedOrderUid;

    constructor() {
        FACTORY = IFactory(msg.sender);
        // init core values
        (BACKER, BACKING_ASSET, STABLE_CRC, STABLE_CRC_AMOUNT, USDC, USDC_AMOUNT) = FACTORY.backingParameters();
    }

    // Backing logic

    /// @notice Initiates Cowswap order, approves Cowswap to spend USDC and presigns order.
    function initiateCowswapOrder(bytes memory orderUid) external {
        if (msg.sender != address(FACTORY)) revert OnlyFactory();

        // Approve USDC to Vault Relay contract
        IERC20(USDC).approve(VAULT_RELAY, USDC_AMOUNT);

        // Place the order using "setPreSignature"
        COWSWAP_SETTLEMENT.setPreSignature(orderUid, true);

        // Store the order UID
        storedOrderUid = orderUid;

        // Emit event with the order UID
        emit OrderCreated(orderUid);
    }

    /// @notice Method, which should be used as Cowswap posthook interaction.
    ///         Creates preconfigured LBP and provides liquidity to it.
    function createLBP() external {
        if (lbp != address(0)) revert AlreadyCreated();
        // Check if the order has been filled on the CowSwap settlement contract
        uint256 filledAmount = COWSWAP_SETTLEMENT.filledAmount(storedOrderUid);
        address backingAsset;
        uint256 backingAmount;
        if (filledAmount == 0) {
            // use USDC to back in case cowswap order is not executed
            backingAsset = USDC;
            backingAmount = USDC_AMOUNT;
        } else {
            // use picked backing asset in case cowswap order is executed
            backingAsset = BACKING_ASSET;
            backingAmount = IERC20(backingAsset).balanceOf(address(this));
            if (backingAmount == 0) revert InsufficientBackingAssetBalance();
        }

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
