// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {GroupLBPFactory} from "src/base-group/GroupLBPFactory.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

contract DeployFactory is Script {
    address deployer = address(0x915aec9009a847a8EB1f65bA87dC02742E37B9D1);
    GroupLBPFactory public groupLBPFactory; // 0xcA5dBf14434bE4F80b83A06AFCA402458B822abC

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        groupLBPFactory = new GroupLBPFactory();

        vm.stopBroadcast();
        console.log(address(groupLBPFactory), "GroupLBPFactory");
    }
}
