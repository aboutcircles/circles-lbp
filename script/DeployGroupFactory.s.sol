// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {GroupLBPFactory} from "src/base-group/GroupLBPFactory.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

contract DeployFactory is Script {
    address deployer = address(0xaAb15A045e74c6539B696B115e763A22BE5C9594);
    GroupLBPFactory public groupLBPFactory; // 0x3B36d73506C3e75FcaCB27340faA38ade1CBaF0a

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        groupLBPFactory = new GroupLBPFactory();

        vm.stopBroadcast();
        console.log(address(groupLBPFactory), "GroupLBPFactory");
    }
}
