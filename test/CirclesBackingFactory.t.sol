// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CirclesBackingFactory} from "src/factory/CirclesBackingFactory.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {INoProtocolFeeLiquidityBootstrappingPoolFactory} from "src/interfaces/ILBPFactory.sol";
import {ILBP} from "src/interfaces/ILBP.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CirclesBackingFactoryTest is Test {
    CirclesBackingFactory public factory;
    address factoryAdmin = address(0x4583759874359754305480345);
    address testAccount = address(0x458437598234234234);
    address personalCRC;
    address backingAsset;
    address VAULT;
    uint256 usdcStartAmount = 100e6;

    uint256 blockNumber = 37968717;
    uint256 gnosis;

    function setUp() public {
        gnosis = vm.createFork(vm.envString("GNOSIS_RPC"), blockNumber);
        vm.selectFork(gnosis);
        factory = new CirclesBackingFactory(factoryAdmin);
        VAULT = factory.VAULT();
    }

    function test_Start() public {}
}
