// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TestLBPMintPolicy} from "src/policy/TestLBPMintPolicy.sol";
import {CreateTestProxyLBPMintPolicy} from "src/proxy/CreateTestProxyLBPMintPolicy.sol";

contract DeployMintPolicy is Script {
    address deployer = address(0x6BF173798733623cc6c221eD52c010472247d861);
    TestLBPMintPolicy public mintPolicy; // 0xCb10eC7A4D9D764b1DcfcB9c2EBa675B1e756C96
    CreateTestProxyLBPMintPolicy public proxyDeployer; // 0x777f78921890Df5Db755e77CbA84CBAdA5DB56D2

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        mintPolicy = new TestLBPMintPolicy();
        proxyDeployer = new CreateTestProxyLBPMintPolicy(address(mintPolicy));

        vm.stopBroadcast();
        console.log(address(mintPolicy), "MintPolicy");
        console.log(address(proxyDeployer), "ProxyDeployer");
    }
}
