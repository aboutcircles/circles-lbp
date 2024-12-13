// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {RedeemHelper} from "src/helpers/RedeemHelper.sol";

contract DeployRedeemHelper is Script {
    address deployer = address(0x6BF173798733623cc6c221eD52c010472247d861);
    RedeemHelper public redeemHelper; // 0x8D46BA60Bf0c4A93d21dc1Db8F230Bdf1E7764A3

    function setUp() public {}

    function run() public {
        vm.startBroadcast(deployer);

        redeemHelper = new RedeemHelper();

        vm.stopBroadcast();
        console.log(address(redeemHelper), "RedeemHelper");
    }
}
