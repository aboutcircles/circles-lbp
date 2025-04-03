// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CirclesBackingFactory} from "src/CirclesBackingFactory.sol";

contract DeployFactory is Script {
    address deployer = address(0x2AEE0499c7E6df0b9639815C0592A835f62D7e2a);
    CirclesBackingFactory public circlesBackingFactory; // 0x00c99CebB2FD24545e248Aa6aF2F4432D4b6349a
    // order 0xaBEfc5bFcab0aFbf9a4191C3D78887a7007EfE73
    // value 0xB2A2541D5002284a7542fcB2e4771490B7AE4d08

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        circlesBackingFactory = new CirclesBackingFactory(deployer, 10);

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
