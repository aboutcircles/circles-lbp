// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {TestRenounceableProxy} from "src/proxy/TestRenounceableProxy.sol";

/**
 * @title Test Deployer of UpgradeableRenounceableProxy with LBPMintPolicy.
 * @notice Test version. Contract allows Safe to create test version of
 *         UpgradeableRenounceableProxy with test version of LBPMintPolicy
 *         as an implementation.
 */
contract CreateTestProxyLBPMintPolicy {
    /// Method can be called only via delegatecall.
    error OnlyDelegateCall();

    /// @notice Emitted when a new proxy is created
    event ProxyCreation(address indexed proxy);

    /// @dev Stores contract address to restrict call usage.
    address immutable thisAddress;
    /// @notice Test version of LBPMintPolicy used as an implementation by newly created proxy.
    address public immutable testLBPMintPolicyImplementation;

    /// @notice Constructor initializes immutables.
    constructor(address _testLBPMintPolicyImplementation) {
        thisAddress = address(this);
        testLBPMintPolicyImplementation = _testLBPMintPolicyImplementation;
    }

    /**
     * @notice Method is expected to be called by Safe using delegatecall.
     *         Deploys a proxy with EIP1967 admin msg.sender (Safe via delegatecall).
     *         During deployment calls EIP1967 upgradeToAndCall with TestLBPMintPolicy as an implementation.
     */
    function createTestProxyMintPolicy() external {
        if (address(this) == thisAddress) revert OnlyDelegateCall();
        bytes memory data = abi.encodeWithSignature("initialize()");
        address proxy = address(new TestRenounceableProxy(testLBPMintPolicyImplementation, data));
        emit ProxyCreation(proxy);
    }
}
