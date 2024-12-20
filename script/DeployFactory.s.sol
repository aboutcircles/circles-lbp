// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TestCirclesLBPFactory} from "src/factory/TestCirclesLBPFactory.sol";

contract DeployFactory is Script {
    address deployer = address(0x6BF173798733623cc6c221eD52c010472247d861);
    TestCirclesLBPFactory public circlesLBPFactory;

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        circlesLBPFactory = new TestCirclesLBPFactory();

        vm.stopBroadcast();
        console.log(address(circlesLBPFactory), "CirclesLBPFactory");
    }
}
