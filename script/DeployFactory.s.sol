// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CirclesBackingFactory} from "src/factory/CirclesBackingFactory.sol";

contract DeployFactory is Script {
    address deployer = address(0x6BF173798733623cc6c221eD52c010472247d861);
    CirclesBackingFactory public circlesBackingFactory;

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        circlesBackingFactory = new CirclesBackingFactory(deployer, 1);

        vm.stopBroadcast();
        console.log(address(circlesBackingFactory), "CirclesBackingFactory");
    }
}
