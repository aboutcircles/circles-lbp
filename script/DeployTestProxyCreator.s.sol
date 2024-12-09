// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CreateTestProxyLBPMintPolicy} from "src/proxy/CreateTestProxyLBPMintPolicy.sol";

contract DeployTestProxyCreator is Script {
    address internal testLBPMintPolicyImplementation;
    CreateTestProxyLBPMintPolicy public proxyCreator;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        proxyCreator = new CreateTestProxyLBPMintPolicy(testLBPMintPolicyImplementation);

        vm.stopBroadcast();
    }
}
