// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CirclesBackingFactory} from "src/factory/CirclesBackingFactory.sol";

contract DeployFactory is Script {
    address deployer = address(0x6BF173798733623cc6c221eD52c010472247d861);
    CirclesBackingFactory public circlesBackingFactory; // 0xD608978aD1e1473fa98BaD368e767C5b11e3b3cE

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        circlesBackingFactory = new CirclesBackingFactory(deployer, 1);

        vm.stopBroadcast();
        console.log(address(circlesBackingFactory), "CirclesBackingFactory");
    }
}

/*
curl -X 'POST' \
  'https://api.cow.fi/xdai/api/v1/orders' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
  "sellToken": "0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0",
  "buyToken": "0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1",
  "receiver": "0xe75F06c807038D7D38e4f9716FF953eA1dA39157",
  "sellAmount": "1000000",
  "buyAmount": "1",
  "validTo": 1894324190,
  "feeAmount": "0",
  "kind": "sell",
  "partiallyFillable": false,
  "sellTokenBalance": "erc20",
  "buyTokenBalance": "erc20",
  "signingScheme": "presign",
  "signature": "0x",
  "from": "0xe75F06c807038D7D38e4f9716FF953eA1dA39157",
  "appData": "{\"version\":\"1.1.0\",\"appCode\":\"Circles backing powered by AboutCircles\",\"metadata\":{\"hooks\":{\"version\":\"0.1.0\",\"post\":[{\"target\":\"0xe75f06c807038d7d38e4f9716ff953ea1da39157\",\"callData\":\"0x13e8f89f\",\"gasLimit\":\"6000000\"}]}}}"
}'
*/
