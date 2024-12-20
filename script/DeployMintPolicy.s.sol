// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CreateTestProxyLBPMintPolicy} from "src/proxy/CreateTestProxyLBPMintPolicy.sol";
import {MintPolicy} from "circles-contracts-v2/groups/BaseMintPolicy.sol";

contract DeployMintPolicy is Script {
    address deployer = address(0x6BF173798733623cc6c221eD52c010472247d861);
    MintPolicy public mintPolicy;
    CreateTestProxyLBPMintPolicy public proxyDeployer;

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        mintPolicy = new MintPolicy();
        proxyDeployer = new CreateTestProxyLBPMintPolicy(address(mintPolicy));

        vm.stopBroadcast();
        console.log(address(mintPolicy), "MintPolicy");
        console.log(address(proxyDeployer), "ProxyDeployer");
    }
}
