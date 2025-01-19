// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IVault} from "src/interfaces/IVault.sol";

interface IFactory {
    function getAppData(address _circlesBackingInstance)
        external
        pure
        returns (string memory appDataString, bytes32 appDataHash);
    function createLBP(address personalCRC, uint256 personalCRCAmount, address backingAsset, uint256 backingAssetAmount)
        external
        returns (address lbp, bytes32 poolId, IVault.JoinPoolRequest memory request, address vault);
    function releaseTimestamp() external view returns (uint32);
    function notifyRelease(address lbp) external;
    function backingParameters()
        external
        view
        returns (
            address backer,
            address backingAsset,
            address personalStableCRC,
            uint256 stableCRCAmount,
            address usdc,
            uint256 usdcAmount
        );
}
