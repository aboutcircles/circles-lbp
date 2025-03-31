// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CirclesBackingFactory} from "src/CirclesBackingFactory.sol";

contract DeployFactory is Script {
    address deployer = address(0x2AEE0499c7E6df0b9639815C0592A835f62D7e2a);
    CirclesBackingFactory public circlesBackingFactory; // 0xbe6f38445bCddAbeC8819c746C2C884DC0cDD3e1
    // order 0xc2c4452A93795ea667bE9e2c747B811020DEdD69
    // value 0xed6CD78617C38fAf1c5696021bB6b7a331Ad38a4

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        circlesBackingFactory = new CirclesBackingFactory(deployer, 1);

        vm.stopBroadcast();
        console.log(address(circlesBackingFactory), "CirclesBackingFactory");
    }
}

/*
Register app data

curl -X 'PUT' \
  'https://api.cow.fi/xdai/api/v1/app_data' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
  "fullAppData": "{\"version\":\"1.1.0\",\"appCode\":\"Circles backing powered by AboutCircles\",\"metadata\":{\"hooks\":{\"version\":\"0.1.0\",\"post\":[{\"target\":\"0x62313a160cd50dc151b9cd0466f895722835a9da\",\"callData\":\"0x13e8f89f\",\"gasLimit\":\"6000000\"}]}}}"
}'
*/