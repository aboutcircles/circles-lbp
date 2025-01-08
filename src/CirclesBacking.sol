// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICowswapSettlement} from "src/interfaces/ICowswapSettlement.sol";
import {IFactory} from "src/interfaces/IFactory.sol"; // temporary solution

contract CirclesBacking {
    /// Already initialized.
    error AlreadyInitialized();

    address public constant COWSWAP_SETTLEMENT_CONTRACT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address public constant VAULT_RELAY = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    address public backer;
    address public backingAsset;
    address public personalCircles;

    bytes public storedOrderUid;

    event OrderCreated(bytes32 orderHash);

    constructor() {}

    function initAndCreateOrder(
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
        ICowswapSettlement cowswapSettlement = ICowswapSettlement(COWSWAP_SETTLEMENT_CONTRACT);
        cowswapSettlement.setPreSignature(orderUid, true);

        // Emit event with the order UID
        //emit OrderCreated(orderDigest);
    }

    function checkOrderFilledAndTransfer() public {
        // Check if the order has been filled on the CowSwap settlement contract
        ICowswapSettlement cowswapSettlement = ICowswapSettlement(COWSWAP_SETTLEMENT_CONTRACT);
        uint256 filledAmount = cowswapSettlement.filledAmount(storedOrderUid);

        require(filledAmount > 0, "Order not filled yet");

        // Check GNO balance of the contract
        //uint256 gnoBalance = IERC20(GNO).balanceOf(address(this));
        //require(gnoBalance > 0, "No GNO balance to transfer");

        // Transfer GNO to the receiver
        //bool success = IERC20(GNO).transfer(backer, gnoBalance);
        //require(success, "GNO transfer failed");
    }
}
