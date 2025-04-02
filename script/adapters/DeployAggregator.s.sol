// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AggregatorSDAI} from "src/adapters/AggregatorSDAI.sol";

contract DeployAggregator is Script {
    address deployer = address(0x2AEE0499c7E6df0b9639815C0592A835f62D7e2a);
    AggregatorSDAI public aggregatorSDAI; // 0x60F37d5bE3dBe352aD87f043F0BD5bF6cf9BbA78

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        aggregatorSDAI = new AggregatorSDAI();

        vm.stopBroadcast();
        console.log(address(aggregatorSDAI), "AggregatorSDAI");
    }
}
