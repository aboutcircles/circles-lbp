// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGetUid} from "src/interfaces/IGetUid.sol";
import {ICowswapSettlement} from "src/interfaces/ICowswapSettlement.sol";
import {IFactory} from "src/interfaces/IFactory.sol"; // temporary solution

contract CirclesBacking {
    address public constant USDC = 0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0;
    uint256 public constant USDC_DECIMALS = 1e6;
    uint256 public constant TRADE_AMOUNT = 100 * USDC_DECIMALS;
    uint32 public constant VALID_TO = uint32(1894006860); // timestamp in 5 years

    address public constant COWSWAP_SETTLEMENT_CONTRACT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address public constant VAULT_RELAY = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
    address public constant GET_UID_CONTRACT = 0xCA51403B524dF7dA6f9D6BFc64895AD833b5d711;

    address public constant WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
    address public constant GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;

    address public backer;
    address public backingAsset;
    address public personalCircles;
    bytes32 public appData;

    bytes public storedOrderUid;

    event OrderCreated(bytes32 orderHash);

    constructor(address _backer, address _backingAsset, address _personalCircles) {
        backer = _backer;
        backingAsset = _backingAsset;
        personalCircles = _personalCircles;
        (, bytes32 appDataHash) = IFactory(msg.sender).getAppData(address(this)); // temporary solution
        appData = appDataHash;
    }

    function createOrder() external {
        // Approve USDC to Vault Relay contract
        IERC20(USDC).approve(VAULT_RELAY, TRADE_AMOUNT);

        // Generate order UID using the "getUid" contract
        IGetUid getUidContract = IGetUid(GET_UID_CONTRACT);

        (bytes32 orderDigest,) = getUidContract.getUid(
            WXDAI,
            GNO,
            address(this), // Use contract address as the receiver
            TRADE_AMOUNT,
            1, // Determined by off-chain logic or Cowswap solvers
            VALID_TO, // ValidTo timestamp
            appData,
            0, // FeeAmount
            true, // IsSell
            false // PartiallyFillable
        );

        // Construct the order UID
        bytes memory orderUid = abi.encodePacked(orderDigest, address(this), uint32(VALID_TO));

        // Store the order UID
        storedOrderUid = orderUid;

        // Place the order using "setPreSignature"
        ICowswapSettlement cowswapSettlement = ICowswapSettlement(COWSWAP_SETTLEMENT_CONTRACT);
        cowswapSettlement.setPreSignature(orderUid, true);

        // Emit event with the order UID
        emit OrderCreated(orderDigest);
    }

    function checkOrderFilledAndTransfer() public {
        // Check if the order has been filled on the CowSwap settlement contract
        ICowswapSettlement cowswapSettlement = ICowswapSettlement(COWSWAP_SETTLEMENT_CONTRACT);
        uint256 filledAmount = cowswapSettlement.filledAmount(storedOrderUid);

        require(filledAmount > 0, "Order not filled yet");

        // Check GNO balance of the contract
        uint256 gnoBalance = IERC20(GNO).balanceOf(address(this));
        require(gnoBalance > 0, "No GNO balance to transfer");

        // Transfer GNO to the receiver
        bool success = IERC20(GNO).transfer(backer, gnoBalance);
        require(success, "GNO transfer failed");
    }
}
