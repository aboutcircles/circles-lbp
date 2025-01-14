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
        (BACKER, BACKING_ASSET, STABLE_CRC, STABLE_CRC_AMOUNT) = FACTORY.backingParameters();
    }

    // Backing logic

    /// @notice Initiates Cowswap order, approves Cowswap to spend USDC and presigns order.
    function initiateCowswapOrder(address usdc, uint256 tradeAmount, bytes memory orderUid) external {
        if (msg.sender != address(FACTORY)) revert OnlyFactory();

        // Approve USDC to Vault Relay contract
        IERC20(usdc).approve(VAULT_RELAY, tradeAmount);

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
        // Check if the order has been filled on the CowSwap settlement contract
        uint256 filledAmount = COWSWAP_SETTLEMENT.filledAmount(storedOrderUid);
        if (filledAmount == 0) revert OrderNotFilledYet();
        if (lbp != address(0)) revert AlreadyCreated();

        // Backing asset balance of the contract
        uint256 backingAssetBalance = IERC20(BACKING_ASSET).balanceOf(address(this));
        if (backingAssetBalance == 0) revert InsufficientBackingAssetBalance();

        // Create LBP
        bytes32 poolId;
        IVault.JoinPoolRequest memory request;
        address vault;
        (lbp, poolId, request, vault) =
            FACTORY.createLBP(STABLE_CRC, STABLE_CRC_AMOUNT, BACKING_ASSET, backingAssetBalance);

        // approve vault
        IERC20(STABLE_CRC).approve(vault, STABLE_CRC_AMOUNT);
        IERC20(BACKING_ASSET).approve(vault, backingAssetBalance);

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
