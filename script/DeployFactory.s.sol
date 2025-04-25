// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CirclesBackingFactory} from "src/CirclesBackingFactory.sol";

contract DeployFactory is Script {
    address deployer = address(0xaAb15A045e74c6539B696B115e763A22BE5C9594);
    address admin = address(0x7ADd2C8D1f7CE98cA9a6A7c0122916787988071F);
    CirclesBackingFactory public circlesBackingFactory; // 0xecEd91232C609A42F6016860E8223B8aEcaA7bd0
    // order 0x43866C5602B0E3b3272424396e88b849796Dc608
    // value 0x630E480d67f807082843C9f0ab44918BDce7A018

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        circlesBackingFactory = new CirclesBackingFactory(admin, 100);

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
