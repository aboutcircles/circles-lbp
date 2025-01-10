// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICowswapSettlement} from "src/interfaces/ICowswapSettlement.sol";
import {IFactory} from "src/interfaces/IFactory.sol"; // temporary solution
import {ILBP} from "src/interfaces/ILBP.sol";
import {IVault} from "src/interfaces/IVault.sol";

contract CirclesBacking {
    /// Already initialized.
    error AlreadyInitialized();
    /// Function must be called only by Cowswap posthook.
    error OrderNotFilledYet();
    /// Cowswap solver must transfer the swap result before calling posthook.
    error InsufficientBackingAssetBalance();
    /// Unauthorized access.
    error NotBacker();
    /// Balancer Pool Tokens are still locked.
    error TokensLockedUntilTimestamp(uint256 timestamp);

    ICowswapSettlement public constant COWSWAP_SETTLEMENT =
        ICowswapSettlement(address(0x9008D19f58AAbD9eD0D60971565AA8510560ab41));
    address public constant VAULT_RELAY = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
    address public constant VAULT_BALANCER = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IFactory internal immutable FACTORY;
    /// @notice Amount of InflationaryCircles to use in LBP initial liquidity.
    uint256 public constant CRC_AMOUNT = 48 ether;
    /// @dev LBP token weight 50%.
    uint256 internal constant WEIGHT_50 = 0.5 ether;
    /// @dev Update weight duration is set to 1 year.
    uint256 internal constant UPDATE_WEIGHT_DURATION = 365 days;

    address public backer;
    address public backingAsset;
    address public personalCircles;
    address public lbp;
    uint256 public balancerPoolTokensUnlockTimestamp;

    bytes public storedOrderUid;

    event OrderCreated(bytes orderUid);

    constructor() {
        FACTORY = IFactory(msg.sender);
    }

    function initiateBacking(
        address _backer,
        address _backingAsset,
        address _personalCircles,
        bytes memory orderUid,
        address usdc,
        uint256 tradeAmount
    ) external {
        if (backer != address(0)) revert AlreadyInitialized();
        // init
        backer = _backer;
        backingAsset = _backingAsset;
        personalCircles = _personalCircles;

        // Approve USDC to Vault Relay contract
        IERC20(usdc).approve(VAULT_RELAY, tradeAmount);

        // Store the order UID
        storedOrderUid = orderUid;

        // Place the order using "setPreSignature"
        COWSWAP_SETTLEMENT.setPreSignature(orderUid, true);

        // Emit event with the order UID
        emit OrderCreated(orderUid);
    }

    function createLBP() external {
        // Check if the order has been filled on the CowSwap settlement contract
        uint256 filledAmount = COWSWAP_SETTLEMENT.filledAmount(storedOrderUid);
        if (filledAmount == 0) revert OrderNotFilledYet();

        // Backing asset balance of the contract
        uint256 backingAssetBalance = IERC20(backingAsset).balanceOf(address(this));
        if (backingAssetBalance == 0) revert InsufficientBackingAssetBalance();

        // Create LBP
        bytes32 poolId;
        IVault.JoinPoolRequest memory request;

        (lbp, poolId, request) = FACTORY.createLBP(personalCircles, backingAsset, backingAssetBalance);

        // approve vault
        IERC20(personalCircles).approve(VAULT_BALANCER, backingAssetBalance);
        IERC20(backingAsset).approve(VAULT_BALANCER, CRC_AMOUNT);

        // provide liquidity into lbp
        IVault(VAULT_BALANCER).joinPool(
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

        // need to lock, so only 1 call
    }

    function claimBalancerPoolTokens() external {
        if (msg.sender != backer) revert NotBacker();
        /*
        if ()

        if (unlockTimestamp == 0) revert NotAUser();
        if (unlockTimestamp > block.timestamp) revert TokensLockedUntilTimestamp(unlockTimestamp);
        userToLBPData[msg.sender].bptUnlockTimestamp = 0;

        IERC20 lbp = IERC20(userToLBPData[msg.sender].lbp);
        uint256 bptAmount = lbp.balanceOf(address(this));
        lbp.transfer(msg.sender, bptAmount);
        */
    }

    function _endWeights() internal pure returns (uint256[] memory endWeights) {
        endWeights = new uint256[](2);
        endWeights[0] = WEIGHT_50;
        endWeights[1] = WEIGHT_50;
    }
}
