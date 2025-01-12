// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CirclesBacking} from "src/CirclesBacking.sol";
import {CirclesBackingFactory} from "src/factory/CirclesBackingFactory.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {ILBP} from "src/interfaces/ILBP.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHub} from "src/interfaces/IHub.sol";

contract CirclesBackingFactoryTest is Test {
    address public constant COWSWAP_SETTLEMENT = address(0x9008D19f58AAbD9eD0D60971565AA8510560ab41);
    IHub public constant HUB_V2 = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));
    CirclesBackingFactory public factory;
    address factoryAdmin = address(0x4583759874359754305480345);
    address testAccount = address(0x0865d14a4B688F24Bc8C282045A4A3cb9a26FbC2);
    address WETH = address(0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1);
    address personalCRC;
    address backingAsset;
    address VAULT;
    address USDC;
    uint256 usdcStartAmount = 100e6;
    uint256 CRC_AMOUNT;

    uint256 blockNumber = 37997675;
    uint256 gnosis;

    bytes public uid;

    function setUp() public {
        gnosis = vm.createFork(vm.envString("GNOSIS_RPC"), blockNumber);
        vm.selectFork(gnosis);
        factory = new CirclesBackingFactory(factoryAdmin, uint256(100));
        VAULT = factory.VAULT();
        USDC = factory.USDC();
        CRC_AMOUNT = factory.CRC_AMOUNT();
    }

    function test_BackingFlow() public {
        address predictedInstance = factory.computeAddress(testAccount);

        // first fill test account with 100 USDC
        deal(USDC, testAccount, usdcStartAmount);

        // next approve factory to spend usdc
        vm.prank(testAccount);
        IERC20(USDC).approve(address(factory), usdcStartAmount);

        // next transfer 48CRC to factory with WETH encoded as backing asset
        bytes memory data = abi.encode(WETH);
        vm.prank(testAccount);
        HUB_V2.safeTransferFrom(testAccount, address(factory), uint256(uint160(testAccount)), CRC_AMOUNT, data);

        // next simulate actions done by cowswap solvers
        // 1. set some instance balance of backing asset
        deal(WETH, predictedInstance, 0.03 ether);
        // 2. set settlement contract state filledAmount at uid key with 0.03 ether
        uid = CirclesBacking(predictedInstance).storedOrderUid();
        bytes32 slot = keccak256(abi.encodePacked(uid, uint256(2)));
        vm.store(COWSWAP_SETTLEMENT, slot, bytes32(uint256(0.03 ether)));

        // next call createLBP instead of cowswap solver
        CirclesBacking(predictedInstance).createLBP();
    }
}
