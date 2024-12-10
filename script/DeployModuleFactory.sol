// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TestTrustModule} from "src/module/TestTrustModule.sol";
import {TestCirclesLBPFactory} from "src/factory/TestCirclesLBPFactory.sol";

contract DeployModuleFactory is Script {
    address deployer = address(0x6BF173798733623cc6c221eD52c010472247d861);
    TestTrustModule public trustModule; // 0x56652E53649F20C6a360Ea5F25379F9987cECE82
    TestCirclesLBPFactory public circlesLBPFactory; // 0x97030b525248cAc78aabcc33D37139BfB5a34750

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        trustModule = new TestTrustModule();
        circlesLBPFactory = new TestCirclesLBPFactory(); 

        vm.stopBroadcast();
        console.log(address(trustModule), "TrustModule");
        console.log(address(circlesLBPFactory), "CirclesLBPFactory");
    }
}
