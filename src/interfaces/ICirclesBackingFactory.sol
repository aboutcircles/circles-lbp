// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IVault} from "src/interfaces/IVault.sol";
// TODO: refactor libs into interfaces

library GPv2Order {
    struct Data {
        address sellToken;
        address buyToken;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        uint256 feeAmount;
        bytes32 kind;
        bool partiallyFillable;
        bytes32 sellTokenBalance;
        bytes32 buyTokenBalance;
    }
}

library IConditionalOrder {
    struct ConditionalOrderParams {
        address handler;
        bytes32 salt;
        bytes staticInput;
    }
}

interface ICirclesBackingFactory {
    error BackingInFavorDisallowed();
    error CirclesBackingDeploymentFailed(address backer);
    error NotAdmin();
    error NotExactlyRequiredCRCAmount(uint256 required, uint256 received);
    error OnlyCirclesBacking();
    error OnlyHub();
    error OnlyHumanAvatarsAreSupported();
    error OnlyTwoTokenLBPSupported();
    error UnsupportedBackingAsset(address requestedAsset);

    event CirclesBackingCompleted(address indexed backer, address indexed circlesBackingInstance, address indexed lbp);
    event CirclesBackingDeployed(address indexed backer, address indexed circlesBackingInstance);
    event CirclesBackingInitiated(
        address indexed backer,
        address indexed circlesBackingInstance,
        address backingAsset,
        address personalCirclesAddress
    );
    event LBPDeployed(address indexed circlesBackingInstance, address indexed lbp);
    event Released(address indexed backer, address indexed circlesBackingInstance, address indexed lbp);

    function ADMIN() external view returns (address);
    function CRC_AMOUNT() external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function HUB_V2() external view returns (address);
    function INSTANCE_BYTECODE_HASH() external view returns (bytes32);
    function LBP_FACTORY() external view returns (address);
    function LIFT_ERC20() external view returns (address);
    function TRADE_AMOUNT() external view returns (uint256);
    function USDC() external view returns (address);
    function VAULT() external view returns (address);
    function backerOf(address circlesBacking) external view returns (address backer);
    function backingParameters()
        external
        view
        returns (
            address transientBacker,
            address transientBackingAsset,
            address transientStableCRC,
            uint256 transientStableCRCAmount,
            bytes32 transientAppData,
            address usdc,
            uint256 usdcAmount
        );
    function circlesBackingOrder() external view returns (address);
    function computeAddress(address backer) external view returns (address predictedAddress);
    function createLBP(address personalCRC, uint256 personalCRCAmount, address backingAsset, uint256 backingAssetAmount)
        external
        returns (address lbp, bytes32 poolId, IVault.JoinPoolRequest memory request, address vault);
    function exitLBP(address lbp, uint256 bptAmount, uint256 minAmountOut0, uint256 minAmountOut1) external;
    function getAppData(address _circlesBackingInstance)
        external
        pure
        returns (string memory appDataString, bytes32 appDataHash);
    function getConditionalParamsAndOrderUid(address owner, address backingAsset, uint32 orderDeadline, bytes32 appData)
        external
        view
        returns (uint256 buyAmount, IConditionalOrder.ConditionalOrderParams memory params, bytes memory orderUid);
    function getOrder(address owner, address buyToken, uint256 buyAmount, uint32 validTo, bytes32 appData)
        external
        view
        returns (GPv2Order.Data memory order);
    function getPersonalCircles(address avatar) external returns (address inflationaryCircles);
    function isActiveLBP(address backer) external view returns (bool);
    function notifyRelease(address lbp) external;
    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes memory data)
        external
        returns (bytes4);
    function postAppData() external view returns (string memory);
    function preAppData() external view returns (string memory);
    function releaseTimestamp() external view returns (uint32);
    function setReleaseTimestamp(uint32 timestamp) external;
    function setSupportedBackingAssetStatus(address backingAsset, bool status) external;
    function supportedBackingAssets(address supportedAsset) external view returns (bool);
    function valueFactory() external view returns (address);
}
