// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICowswapSettlement} from "src/interfaces/ICowswapSettlement.sol";
import {IFactory} from "src/interfaces/IFactory.sol";
import {ILBP} from "src/interfaces/ILBP.sol";
import {IVault} from "src/interfaces/IVault.sol";

contract CirclesBacking {
    // Errors
    /// Already initialized.
    error AlreadyInitialized();
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
    /// @dev Circles Backing Factory.
    IFactory internal immutable FACTORY;
    /// @dev LBP token weight 50%.
    uint256 internal constant WEIGHT_50 = 0.5 ether;
    /// @dev Update weight duration and lbp lock period is set to 1 year.
    uint256 internal constant UPDATE_WEIGHT_DURATION = 365 days;

    // Storage
    /// @notice Address of circles avatar, which has backed his personal circles.
    address public backer;
    /// @notice Address of one of supported assets, which was used to back circles.
    address public backingAsset;
    /// @notice Address of ERC20 stable circles version (InflationaryCircles), which is used as underlying asset in lbp.
    address public personalCircles;
    /// @notice Address of created Liquidity Bootstrapping Pool, which represents backing liquidity.
    address public lbp;
    uint256 stableCirclesAmount;
    /// @notice Timestamp, when locked balancer pool tokens are allowed to be claimed by backer.
    uint256 public balancerPoolTokensUnlockTimestamp;
    /// @notice Cowswap order uid.
    bytes public storedOrderUid;

    constructor() {
        FACTORY = IFactory(msg.sender);
    }

    // Backing logic

    /// @notice Initiates core values and backing process, approves Cowswap to spend USDC and presigns order.
    function initiateBacking(
        address _backer,
        address _backingAsset,
        address _personalCircles,
        bytes memory orderUid,
        address usdc,
        uint256 tradeAmount,
        uint256 stableCRCAmount
    ) external {
        if (backer != address(0)) revert AlreadyInitialized();
        // init
        backer = _backer;
        backingAsset = _backingAsset;
        personalCircles = _personalCircles;
        stableCirclesAmount = stableCRCAmount;

        // Approve USDC to Vault Relay contract
        IERC20(usdc).approve(VAULT_RELAY, tradeAmount);

        // Store the order UID
        storedOrderUid = orderUid;

        // Place the order using "setPreSignature"
        COWSWAP_SETTLEMENT.setPreSignature(orderUid, true);

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
        uint256 backingAssetBalance = IERC20(backingAsset).balanceOf(address(this));
        if (backingAssetBalance == 0) revert InsufficientBackingAssetBalance();

        // Create LBP
        bytes32 poolId;
        IVault.JoinPoolRequest memory request;
        address vault;
        (lbp, poolId, request, vault) =
            FACTORY.createLBP(personalCircles, stableCirclesAmount, backingAsset, backingAssetBalance);

        // approve vault
        IERC20(personalCircles).approve(vault, stableCirclesAmount);
        IERC20(backingAsset).approve(vault, backingAssetBalance);

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
        if (msg.sender != backer) revert NotBacker();

        if (FACTORY.releaseTimestamp() > uint32(block.timestamp)) {
            if (balancerPoolTokensUnlockTimestamp > block.timestamp) {
                revert TokensLockedUntilTimestamp(balancerPoolTokensUnlockTimestamp);
            }
        }
        // zeroed timestamp
        balancerPoolTokensUnlockTimestamp = 0;

        uint256 bptAmount = IERC20(lbp).balanceOf(address(this));
        IERC20(lbp).transfer(receiver, bptAmount);
    }

    // Internal functions

    function _endWeights() internal pure returns (uint256[] memory endWeights) {
        endWeights = new uint256[](2);
        endWeights[0] = WEIGHT_50;
        endWeights[1] = WEIGHT_50;
    }
}
