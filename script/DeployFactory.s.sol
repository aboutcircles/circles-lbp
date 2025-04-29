// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CirclesBackingFactory} from "src/CirclesBackingFactory.sol";

contract DeployFactory is Script {
    address deployer = address(0x2D75A44e14C660fc5d4d30B22aE133b244D6D30B);
    address admin = address(0x7ADd2C8D1f7CE98cA9a6A7c0122916787988071F);
    CirclesBackingFactory public circlesBackingFactory; // 0xc2A92890f14A2f85E0C7825BFaA173F0D087517d
    // order 0x1B843e6623250A6c9F2a49337c0609CFCf83611C.
    // value 0x2B11FAc377A2F75D96B785631FbdcBd78ce2372A.

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        circlesBackingFactory = new CirclesBackingFactory(admin, 10000);

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
