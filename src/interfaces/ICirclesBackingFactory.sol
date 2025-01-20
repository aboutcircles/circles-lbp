// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IVault} from "src/interfaces/IVault.sol";

interface ICirclesBackingFactory {
    error BackingInFavorDissalowed();
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
    function GET_UID_CONTRACT() external view returns (address);
    function HUB_V2() external view returns (address);
    function INSTANCE_BYTECODE_HASH() external view returns (bytes32);
    function LBP_FACTORY() external view returns (address);
    function LIFT_ERC20() external view returns (address);
    function TRADE_AMOUNT() external view returns (uint256);
    function USDC() external view returns (address);
    function VALID_TO() external view returns (uint32);
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
            address usdc,
            uint256 usdcAmount
        );
    function computeAddress(address backer) external view returns (address predictedAddress);
    function createLBP(address personalCRC, uint256 personalCRCAmount, address backingAsset, uint256 backingAssetAmount)
        external
        returns (address lbp, bytes32 poolId, IVault.JoinPoolRequest memory request, address vault);
    function exitLBP(address lbp, uint256 bptAmount) external;
    function generateOrderUID(address instance, address backingAsset, uint256 buyAmount)
        external
        view
        returns (bytes memory orderUid);
    function getAppData(address _circlesBackingInstance)
        external
        pure
        returns (string memory appDataString, bytes32 appDataHash);
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
}
