// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CirclesBacking} from "src/CirclesBacking.sol";
import {CirclesBackingFactory} from "src/factory/CirclesBackingFactory.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {INoProtocolFeeLiquidityBootstrappingPoolFactory} from "src/interfaces/ILBPFactory.sol";
import {ILBP} from "src/interfaces/ILBP.sol";
import {IVault} from "src/interfaces/IVault.sol";

/**
 * @title CirclesBackingFactoryTest
 * @notice Foundry test suite for CirclesBackingFactory and the CirclesBacking instances.
 */
contract CirclesBackingFactoryTest is Test {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 internal constant FORK_BLOCK_NUMBER = 37997675;
    uint256 internal constant USDC_START_AMOUNT = 100e6; // 100 USDC
    uint256 internal constant WETH_DEAL_AMOUNT  = 0.03 ether;
    uint256 internal constant YEAR              = 365 days;
    
    // Use keccak256(abi.encodePacked(uid, ORDER_FILLED_SLOT_INDEX)) for the settlement storage
    uint256 internal constant ORDER_FILLED_SLOT_INDEX = 2;
    
    // Addresses
    address internal constant COWSWAP_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    IHub    internal constant HUB_V2            = IHub(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8);
    INoProtocolFeeLiquidityBootstrappingPoolFactory internal constant LBP_FACTORY =
        INoProtocolFeeLiquidityBootstrappingPoolFactory(0x85a80afee867aDf27B50BdB7b76DA70f1E853062);

    address internal constant FACTORY_ADMIN = address(0x4583759874359754305480345);
    address internal constant TEST_ACCOUNT  = 0x0865d14a4B688F24Bc8C282045A4A3cb9a26FbC2;
    address internal constant TEST_ACCOUNT2 = 0xc175a0c71f1eDA836ebbF3Ab0e32Fc8865FdEe91;
    address internal constant WETH          = 0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1;
    address internal constant USDT          = 0x4ECaBa5870353805a9F068101A40E0f32ed605C6;

    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

    CirclesBackingFactory internal factory;
    address internal VAULT;
    address internal USDC; 
    uint256 internal CRC_AMOUNT;

    // Gnosis fork ID
    uint256 internal gnosisFork;

    // The CowSwap order uid for the test instance
    bytes public uid;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        // Fork from Gnosis
        gnosisFork = vm.createFork(vm.envString("GNOSIS_RPC"), FORK_BLOCK_NUMBER);
        vm.selectFork(gnosisFork);

        // Deploy factory
        factory = new CirclesBackingFactory(FACTORY_ADMIN, 100); // test-specific "fee" if any

        // Retrieve constants from factory
        VAULT      = factory.VAULT();
        USDC       = factory.USDC();
        CRC_AMOUNT = factory.CRC_AMOUNT();
    }

    // -------------------------------------------------------------------------
    // Internal Helpers
    // -------------------------------------------------------------------------

    /**
     * @dev Give `user` some USDC and let them back the Circles with `backingAsset`.
     *      This sets up the typical scenario used in many tests:
     *       1. Fill `user` with USDC_START_AMOUNT
     *       2. Approve the factory to spend USDC
     *       3. Transfer exactly CRC_AMOUNT from Hub -> Factory
     * @return predictedInstance The address of the CirclesBacking instance that will be deployed
     */
    function _initUserWithBackedCRC(
        address user,
        address backingAsset
    ) internal returns (address predictedInstance) {
        predictedInstance = factory.computeAddress(user);

        // Give user USDC
        deal(USDC, user, USDC_START_AMOUNT);

        // Approve factory to spend USDC
        vm.prank(user);
        IERC20(USDC).approve(address(factory), USDC_START_AMOUNT);

        // Transfer exactly CRC_AMOUNT from user to factory (HUB -> factory)
        bytes memory data = abi.encode(backingAsset);
        vm.prank(user);
        HUB_V2.safeTransferFrom(
            user,
            address(factory),
            uint256(uint160(user)),
            CRC_AMOUNT,
            data
        );
    }

    /**
     * @dev Simulate the CowSwap having filled an order by:
     *      1. Dealing `fillAmount` of `backingAsset` to the predicted instance
     *      2. Setting the `fillAmount` in the settlement contract storage
     */
    function _simulateCowSwapFill(
        address predictedInstance,
        address backingAsset,
        uint256 fillAmount
    ) internal {
        // Deal backingAsset to the instance
        deal(backingAsset, predictedInstance, fillAmount);

        // Retrieve the stored orderUid from the CirclesBacking instance
        bytes memory storedUid = CirclesBacking(predictedInstance).storedOrderUid();

        // Craft the storage slot: keccak256(abi.encodePacked(uid, ORDER_FILLED_SLOT_INDEX))
        bytes32 slot = keccak256(abi.encodePacked(storedUid, uint256(ORDER_FILLED_SLOT_INDEX)));

        // Store fillAmount in the settlement contract's slot
        vm.store(COWSWAP_SETTLEMENT, slot, bytes32(uint256(fillAmount)));
    }

    /**
     * @dev Creates an LBP from the predicted CirclesBacking instance (after the order is "filled").
     */
    function _createLBP(address predictedInstance) internal {
        CirclesBacking(predictedInstance).createLBP();
    }

    // -------------------------------------------------------------------------
    // Admin-Only Tests
    // -------------------------------------------------------------------------

    function test_SetReleaseTimestamp() public {
        vm.prank(factory.ADMIN());
        factory.setReleaseTimestamp(0);
    }

    function test_SetSupportedBackingAssetStatus() public {
        vm.prank(factory.ADMIN());
        factory.setSupportedBackingAssetStatus(0x8e5bBbb09Ed1ebdE8674Cda39A0c169401db4252, true);
    }

    function test_RevertIf_UserSetSupportedBackingAssetStatus() public {
        vm.expectRevert(CirclesBackingFactory.NotAdmin.selector);
        factory.setSupportedBackingAssetStatus(0x8e5bBbb09Ed1ebdE8674Cda39A0c169401db4252, false);
    }

    function test_RevertIf_UserSetsReleaseTime() public {
        vm.expectRevert(CirclesBackingFactory.NotAdmin.selector);
        factory.setReleaseTimestamp(0);
    }

    // -------------------------------------------------------------------------
    // Factory Hooks & Access Control
    // -------------------------------------------------------------------------

    function test_RevertIf_FactoryReciveCalledNotByHubV2() public {
        vm.expectRevert(CirclesBackingFactory.OnlyHub.selector);
        factory.onERC1155Received(
            TEST_ACCOUNT,
            address(factory),
            uint256(uint160(TEST_ACCOUNT)),
            CRC_AMOUNT,
            ""
        );
    }

    function test_RevertIf_UserSendsNotEnoughCRC() public {
        // Give testAccount USDC and approve
        deal(USDC, TEST_ACCOUNT, USDC_START_AMOUNT);
        vm.prank(TEST_ACCOUNT);
        IERC20(USDC).approve(address(factory), USDC_START_AMOUNT);

        // Attempt to send CRC_AMOUNT - 1 instead
        bytes memory data = abi.encode(WETH);
        vm.prank(TEST_ACCOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(
                CirclesBackingFactory.NotExactlyRequiredCRCAmount.selector,
                CRC_AMOUNT,
                CRC_AMOUNT - 1
            )
        );
        HUB_V2.safeTransferFrom(
            TEST_ACCOUNT,
            address(factory),
            uint256(uint160(TEST_ACCOUNT)),
            CRC_AMOUNT - 1,
            data
        );
    }

    function test_RevertIf_UserBacksSomeonesTokens() public {
        // Make testAccount2's CRC belong to testAccount2
        vm.prank(TEST_ACCOUNT);
        HUB_V2.trust(TEST_ACCOUNT2, uint96(block.timestamp + YEAR));
        vm.prank(TEST_ACCOUNT2);
        // Transfer some CRC from testAccount2 -> testAccount (so now testAccount2 is the *true* owner)
        HUB_V2.safeTransferFrom(TEST_ACCOUNT2, TEST_ACCOUNT, uint256(uint160(TEST_ACCOUNT2)), CRC_AMOUNT, "");

        // Attempt to back testAccount2's CRC from testAccount -> factory
        bytes memory data = abi.encode(WETH);
        vm.prank(TEST_ACCOUNT);
        vm.expectRevert(CirclesBackingFactory.BackingInFavorDissalowed.selector);
        HUB_V2.safeTransferFrom(
            TEST_ACCOUNT,
            address(factory),
            uint256(uint160(TEST_ACCOUNT2)),
            CRC_AMOUNT,
            data
        );
    }

    // -------------------------------------------------------------------------
    // CirclesBacking + LBP Creation & Release
    // -------------------------------------------------------------------------

    function test_CreateLBP() public {
        // Setup user with CRC and backing
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT, WETH);

        // Simulate the CowSwap fill
        _simulateCowSwapFill(predictedInstance, WETH, WETH_DEAL_AMOUNT);

        // Create LBP
        _createLBP(predictedInstance);
    }

    function test_RevertIf_LBPIsAlreadyCreated() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT, WETH);

        _simulateCowSwapFill(predictedInstance, WETH, WETH_DEAL_AMOUNT);

        // Create LBP first time
        _createLBP(predictedInstance);

        // Try create second time => revert
        vm.expectRevert(CirclesBacking.AlreadyCreated.selector);
        _createLBP(predictedInstance);
    }

    function test_RevertIf_InsufficientBackingAssetOnOrderContract() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT, WETH);

        // We do NOT simulate any fill. That means the instance won't have WETH
        // But we pretend settlement is "filled" with 0.03 ether
        bytes memory storedUid = CirclesBacking(predictedInstance).storedOrderUid();
        bytes32 slot = keccak256(abi.encodePacked(storedUid, uint256(ORDER_FILLED_SLOT_INDEX)));
        vm.store(COWSWAP_SETTLEMENT, slot, bytes32(uint256(WETH_DEAL_AMOUNT)));

        // Attempt to create LBP => revert
        vm.expectRevert(CirclesBacking.InsufficientBackingAssetBalance.selector);
        _createLBP(predictedInstance);
    }

    function test_ReleaseBalancerPoolTokens() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT, WETH);

        // Simulate fill
        _simulateCowSwapFill(predictedInstance, WETH, WETH_DEAL_AMOUNT);

        // Create LBP
        _createLBP(predictedInstance);

        // Warp enough time so that release is possible
        vm.warp(block.timestamp + YEAR);

        // Release from backer
        vm.prank(TEST_ACCOUNT);
        CirclesBacking(predictedInstance).releaseBalancerPoolTokens(TEST_ACCOUNT);
    }

    function test_RevertIf_ReleaseBalancerPoolDeadlineNotMet() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT, WETH);

        // Simulate fill
        _simulateCowSwapFill(predictedInstance, WETH, WETH_DEAL_AMOUNT);

        // Create LBP
        _createLBP(predictedInstance);

        // Attempt to release too soon
        vm.prank(TEST_ACCOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(
                CirclesBacking.TokensLockedUntilTimestamp.selector,
                block.timestamp + YEAR
            )
        );
        CirclesBacking(predictedInstance).releaseBalancerPoolTokens(TEST_ACCOUNT);
    }

    function test_RevertIf_NotBacker() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT, WETH);

        // Simulate fill
        _simulateCowSwapFill(predictedInstance, WETH, WETH_DEAL_AMOUNT);

        // Create LBP
        _createLBP(predictedInstance);
        vm.warp(block.timestamp + YEAR);

        // Some random address tries to release
        vm.prank(address(0));
        vm.expectRevert(CirclesBacking.NotBacker.selector);
        CirclesBacking(predictedInstance).releaseBalancerPoolTokens(TEST_ACCOUNT);
    }

    function test_RevertIf_BackingAssetIsNotSupported() public {
        // Attempt to back with USDT, which is not supported in the factory
        bytes memory data = abi.encode(USDT);
        vm.prank(TEST_ACCOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(
                CirclesBackingFactory.UnsupportedBackingAsset.selector,
                USDT
            )
        );
        HUB_V2.safeTransferFrom(
            TEST_ACCOUNT,
            address(factory),
            uint256(uint160(TEST_ACCOUNT)),
            CRC_AMOUNT,
            data
        );
    }

    function test_RevertIf_BackingNotCirclesAsset() public {
        vm.expectRevert(CirclesBackingFactory.OnlyCirclesBacking.selector);
        // Attempt to call createLBP from the factory with invalid arguments
        factory.createLBP(USDT, CRC_AMOUNT, USDC, 100 ether);
    }

    // -------------------------------------------------------------------------
    // LBP Exits
    // -------------------------------------------------------------------------

    function test_RevertIf_ExitNonDualAssetPool() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT, WETH);
        _simulateCowSwapFill(predictedInstance, WETH, WETH_DEAL_AMOUNT);
        _createLBP(predictedInstance);

        IERC20[] memory tokens = new IERC20[](3);
        uint256[] memory weights = new uint256[](3);
        tokens[0] = IERC20(USDC);
        tokens[1] = IERC20(USDT);
        tokens[2] = IERC20(WETH);

        weights[0] = 0.3 ether;
        weights[1] = 0.3 ether;
        weights[2] = 0.4 ether;
        // Create a 3-token LBP externally (just for testing exitLBP)
        address lbp = LBP_FACTORY.create(
            "testPool",
            "TP",
            tokens,
            weights,
            0.01 ether,
            msg.sender,
            true
        );

        // Put some LP tokens in testAccount
        deal(lbp, TEST_ACCOUNT, 100 ether);

        // Approve the factory
        vm.prank(TEST_ACCOUNT);
        IERC20(lbp).approve(address(factory), 10 ether);

        vm.prank(TEST_ACCOUNT);
        vm.expectRevert(CirclesBackingFactory.OnlyTwoTokenLBPSupported.selector);
        factory.exitLBP(lbp, 1 ether);
    }

    function test_ExitDualAssetPool() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT, WETH);
        _simulateCowSwapFill(predictedInstance, WETH, WETH_DEAL_AMOUNT);
        _createLBP(predictedInstance);

        address lbp = CirclesBacking(predictedInstance).lbp();

        // Give testAccount some LBP tokens
        deal(lbp, TEST_ACCOUNT, 0.01 ether);

        // Approve
        vm.prank(TEST_ACCOUNT);
        IERC20(lbp).approve(address(factory), 0.01 ether);

        // Exit
        vm.prank(TEST_ACCOUNT);
        factory.exitLBP(lbp, 0.01 ether);
    }

    // -------------------------------------------------------------------------
    // Order Fill / Reverts
    // -------------------------------------------------------------------------

    function test_RevertIf_OrderNotFilledYet() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT, WETH);

        vm.expectRevert(CirclesBacking.OrderNotFilledYet.selector);
        _createLBP(predictedInstance);
    }

    function test_RevertIf_DeployingLBPSecondTime() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT, WETH);
        console.log(HUB_V2.balanceOf(TEST_ACCOUNT, uint256(uint160(TEST_ACCOUNT))));

        // Attempt to re-send CRC
        vm.warp(block.timestamp + 1 days);
        bytes memory data = abi.encode(WETH);

        // Should fail with a generic revert (LBP is already deployed)
        vm.prank(TEST_ACCOUNT);
        vm.expectRevert();
        HUB_V2.safeTransferFrom(
            TEST_ACCOUNT,
            address(factory),
            uint256(uint160(TEST_ACCOUNT)),
            CRC_AMOUNT,
            data
        );
    }

    function test_RevertIf_UserIsNotHuman() public {
        // Mock the HUB so that isHuman(avatar) returns false (e.g. avatar is group)
        address user = TEST_ACCOUNT;
        vm.mockCall(
            address(HUB_V2),
            abi.encodeWithSelector(HUB_V2.isHuman.selector, user),
            abi.encode(false)
        );

        // Attempt to back with CRC => should revert with OnlyHumanAvatarsAreSupported
        deal(USDC, user, USDC_START_AMOUNT);
        vm.prank(user);
        IERC20(USDC).approve(address(factory), USDC_START_AMOUNT);

        bytes memory data = abi.encode(WETH);
        vm.prank(user);
        vm.expectRevert(CirclesBackingFactory.OnlyHumanAvatarsAreSupported.selector);
        HUB_V2.safeTransferFrom(
            user,
            address(factory),
            uint256(uint160(user)),
            CRC_AMOUNT,
            data
        );
    }
}
