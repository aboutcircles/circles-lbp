// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {OrderCreator} from "src/prototype/OrderCreator.sol";

contract DeployPrototype is Script {
    address deployer = address(0x6BF173798733623cc6c221eD52c010472247d861);
    OrderCreator public orderCreator;

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        orderCreator = new OrderCreator();
        orderCreator.createOrder();

        vm.stopBroadcast();
        console.log(address(orderCreator), "orderCreator");
    }
}
