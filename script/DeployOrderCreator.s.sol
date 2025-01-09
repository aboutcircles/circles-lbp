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

/*
curl -X 'POST' \
  'https://api.cow.fi/xdai/api/v1/orders' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
  "sellToken": "0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d",
  "buyToken": "0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb",
  "receiver": "0xEA39b6F8F98f91ECCe24A5601FD02DF850d3eC3E",
  "sellAmount": "100000000000000000",
  "buyAmount": "1",
  "validTo": 1894006860,
  "feeAmount": "0",
  "kind": "sell",
  "partiallyFillable": false,
  "sellTokenBalance": "erc20",
  "buyTokenBalance": "erc20",
  "signingScheme": "presign",
  "signature": "0x",
  "from": "0xEA39b6F8F98f91ECCe24A5601FD02DF850d3eC3E",
  "appData": "{\"version\":\"1.1.0\",\"appCode\":\"Zeal powered by Qantura\",\"metadata\":{\"hooks\":{\"version\":\"0.1.0\",\"post\":[{\"target\":\"0xea39b6f8f98f91ecce24a5601fd02df850d3ec3e\",\"callData\":\"0xbb5ae136\",\"gasLimit\":\"200000\"}]}}}"
}'
*/
