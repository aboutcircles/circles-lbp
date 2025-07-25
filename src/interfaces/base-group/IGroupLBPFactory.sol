// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IVault} from "src/interfaces/IVault.sol";

interface IGroupLBPFactory {
    error InvalidAmount();
    error InvalidFinalWeight();
    error InvalidInitWeight();
    error InvalidSwapFee();
    error OnlyBaseGroupsAreSupported();
    error OnlyStarter();
    error OnlyTwoTokenLBPSupported();

    event GroupLBPCreated(address indexed creator, address indexed group, address indexed lbp);
    event LBPStarterCreated(
        address indexed creator,
        address indexed group,
        address indexed asset,
        address lbpStarter,
        uint256 groupAmount,
        uint256 assetAmount,
        uint256 groupInitWeight,
        uint256 groupFinalWeight,
        uint256 swapFee,
        uint256 updateWeightDuration
    );

    function BALANCER_WEIGHTED_MATH() external view returns (address);
    function BASE_GROUP_FACTORY() external view returns (address);
    function HUB_V2() external view returns (address);
    function LBP_FACTORY() external view returns (address);
    function VAULT() external view returns (address);
    function createLBP(
        address asset,
        address stableCRC,
        uint256 stableCRCAmount,
        uint256 assetAmount,
        uint256 weightCRC,
        uint256 swapFee,
        address group
    ) external returns (address lbp, IVault.JoinPoolRequest memory request);
    function createLBPStarter(address group, address asset, uint256 groupAmount, uint256 assetAmount)
        external
        returns (address lbpStarter);
    function createLBPStarter(
        address group,
        address asset,
        uint256 groupAmount,
        uint256 assetAmount,
        uint256 groupInitWeight,
        uint256 groupFinalWeight,
        uint256 swapFee,
        uint256 updateWeightDuration
    ) external returns (address lbpStarter);
    function exitLBP(address lbp, uint256 bptAmount, uint256 minAmountOut0, uint256 minAmountOut1) external;
    function getStableAmount(uint256 demmurageAmount) external view returns (uint256 stableAmount);
    function lbpCreator(address lbp) external view returns (address creator);
    function starterCreator(address starter) external view returns (address creator);
}
