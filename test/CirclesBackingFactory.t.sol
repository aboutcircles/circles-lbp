// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CirclesBacking} from "src/CirclesBacking.sol";
import {CirclesBackingFactory} from "src/factory/CirclesBackingFactory.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {ILiftERC20} from "src/interfaces/ILiftERC20.sol";
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
    uint256 internal constant BACKING_ASSET_DEAL_AMOUNT = 0.03 ether;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant MAX_DELTA = 1e10;

    // Use keccak256(abi.encodePacked(uid, ORDER_FILLED_SLOT)) for the settlement storage
    uint256 internal constant ORDER_FILLED_SLOT = 2;
    // Use for Hub storage
    uint256 internal constant DISCOUNTED_BALANCES_SLOT = 17;
    uint256 internal constant MINT_TIMES_SLOT = 21;

    // Addresses
    address internal constant COWSWAP_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    IHub internal constant HUB_V2 = IHub(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8);
    ILiftERC20 LIFT_ERC20 = ILiftERC20(0x5F99a795dD2743C36D63511f0D4bc667e6d3cDB5);
    INoProtocolFeeLiquidityBootstrappingPoolFactory internal constant LBP_FACTORY =
        INoProtocolFeeLiquidityBootstrappingPoolFactory(0x85a80afee867aDf27B50BdB7b76DA70f1E853062);

    address internal constant FACTORY_ADMIN = address(0x4583759874359754305480345);
    address internal constant WBTC = 0x8e5bBbb09Ed1ebdE8674Cda39A0c169401db4252;
    address internal constant WETH = 0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1;
    address internal constant GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address internal constant sDAI = 0xaf204776c7245bF4147c2612BF6e5972Ee483701;

    address internal constant USDT = 0x4ECaBa5870353805a9F068101A40E0f32ed605C6;

    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

    CirclesBackingFactory internal factory;
    address internal TEST_ACCOUNT_1 = makeAddr("alice");
    address internal TEST_ACCOUNT_2 = makeAddr("bob");
    address internal VAULT;
    address internal USDC;
    uint256 internal CRC_AMOUNT;
    uint64 internal TODAY;

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
        VAULT = factory.VAULT();
        USDC = factory.USDC();
        CRC_AMOUNT = factory.CRC_AMOUNT();

        TODAY = HUB_V2.day(block.timestamp);

        _setMintTime(TEST_ACCOUNT_1);
        _setMintTime(TEST_ACCOUNT_2);
        _setCRCBalance(uint256(uint160(TEST_ACCOUNT_1)), TEST_ACCOUNT_1, TODAY, uint192(CRC_AMOUNT * 2));
        _setCRCBalance(uint256(uint160(TEST_ACCOUNT_2)), TEST_ACCOUNT_2, TODAY, uint192(CRC_AMOUNT * 2));
    }

    // -------------------------------------------------------------------------
    // Internal Helpers
    // -------------------------------------------------------------------------

    /// @dev Sets Hub mint times for account.
    function _setMintTime(address account) internal {
        bytes32 accountSlot = keccak256(abi.encodePacked(uint256(uint160(account)), MINT_TIMES_SLOT));
        uint256 mintTime = block.timestamp << 160;
        vm.store(address(HUB_V2), accountSlot, bytes32(mintTime));
    }

    /// @dev Sets Hub ERC1155 balance of id for account.
    function _setCRCBalance(uint256 id, address account, uint64 lastUpdatedDay, uint192 balance) internal {
        bytes32 idSlot = keccak256(abi.encodePacked(id, DISCOUNTED_BALANCES_SLOT));
        bytes32 accountSlot = keccak256(abi.encodePacked(uint256(uint160(account)), idSlot));
        uint256 discountedBalance = (uint256(lastUpdatedDay) << 192) + balance;
        vm.store(address(HUB_V2), accountSlot, bytes32(discountedBalance));
    }

    /**
     * @dev Give `user` some USDC and let them back the Circles with `backingAsset`.
     *      This sets up the typical scenario used in many tests:
     *       1. Fill `user` with USDC_START_AMOUNT
     *       2. Approve the factory to spend USDC
     *       3. Transfer exactly CRC_AMOUNT from Hub -> Factory
     * @return predictedInstance The address of the CirclesBacking instance that will be deployed
     */
    function _initUserWithBackedCRC(address user, address backingAsset) internal returns (address predictedInstance) {
        predictedInstance = factory.computeAddress(user);

        // Give user USDC
        deal(USDC, user, USDC_START_AMOUNT);

        // Approve factory to spend USDC
        vm.prank(user);
        IERC20(USDC).approve(address(factory), USDC_START_AMOUNT);

        // Transfer exactly CRC_AMOUNT from user to factory (HUB -> factory)
        bytes memory data = abi.encode(backingAsset);
        vm.prank(user);
        HUB_V2.safeTransferFrom(user, address(factory), uint256(uint160(user)), CRC_AMOUNT, data);
    }

    /**
     * @dev Simulate the CowSwap having filled an order by:
     *      1. Dealing `fillAmount` of `backingAsset` to the predicted instance
     *      2. Setting the `fillAmount` in the settlement contract storage
     */
    function _simulateCowSwapFill(address predictedInstance, address backingAsset, uint256 fillAmount) internal {
        // Deal backingAsset to the instance
        deal(backingAsset, predictedInstance, fillAmount);

        // Retrieve the stored orderUid from the CirclesBacking instance
        bytes memory storedUid = CirclesBacking(predictedInstance).storedOrderUid();

        // Craft the storage slot: keccak256(abi.encodePacked(uid, ORDER_FILLED_SLOT))
        bytes32 slot = keccak256(abi.encodePacked(storedUid, uint256(ORDER_FILLED_SLOT)));

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
        vm.prank(FACTORY_ADMIN);
        factory.setReleaseTimestamp(0);

        assertEq(factory.releaseTimestamp(), 0);
    }

    function test_EnabledBackingAssetSupport() public {
        vm.prank(FACTORY_ADMIN);
        factory.setSupportedBackingAssetStatus(USDT, true);
        assertEq(factory.supportedBackingAssets(USDT), true);
    }

    function test_DisableBackingAssetSupport() public {
        test_EnabledBackingAssetSupport();

        vm.prank(FACTORY_ADMIN);
        factory.setSupportedBackingAssetStatus(USDT, false);
        assertEq(factory.supportedBackingAssets(USDT), false);
    }

    function test_RevertIf_UserSetSupportedBackingAssetStatus() public {
        vm.expectRevert(CirclesBackingFactory.NotAdmin.selector);
        factory.setSupportedBackingAssetStatus(USDT, false);
    }

    function test_RevertIf_UserSetsReleaseTime() public {
        vm.expectRevert(CirclesBackingFactory.NotAdmin.selector);
        factory.setReleaseTimestamp(0);
    }

    // -------------------------------------------------------------------------
    // Factory Hooks & Access Control
    // -------------------------------------------------------------------------

    function test_RevertIf_FactoryReceiveCalledNotByHubV2() public {
        vm.expectRevert(CirclesBackingFactory.OnlyHub.selector);
        factory.onERC1155Received(TEST_ACCOUNT_1, address(factory), uint256(uint160(TEST_ACCOUNT_1)), CRC_AMOUNT, "");
    }

    function test_RevertIf_UserSendsIncorrectCRCAmount() public {
        // Attempt to send CRC_AMOUNT - 1 and CRC_AMOUNT + 1
        vm.prank(TEST_ACCOUNT_1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CirclesBackingFactory.NotExactlyRequiredCRCAmount.selector, CRC_AMOUNT, CRC_AMOUNT - 1
            )
        );
        HUB_V2.safeTransferFrom(TEST_ACCOUNT_1, address(factory), uint256(uint160(TEST_ACCOUNT_1)), CRC_AMOUNT - 1, "");

        vm.prank(TEST_ACCOUNT_1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CirclesBackingFactory.NotExactlyRequiredCRCAmount.selector, CRC_AMOUNT, CRC_AMOUNT + 1
            )
        );
        HUB_V2.safeTransferFrom(TEST_ACCOUNT_1, address(factory), uint256(uint160(TEST_ACCOUNT_1)), CRC_AMOUNT + 1, "");
    }

    function test_RevertIf_UserBacksSomeonesTokens() public {
        // Setup a new account
        vm.prank(TEST_ACCOUNT_2);
        // Transfer some personal CRC from someAccount -> testAccount
        HUB_V2.safeTransferFrom(TEST_ACCOUNT_2, TEST_ACCOUNT_1, uint256(uint160(TEST_ACCOUNT_2)), CRC_AMOUNT, "");

        // Attempt to back someAccount's CRC from testAccount -> factory
        vm.prank(TEST_ACCOUNT_1);
        vm.expectRevert(CirclesBackingFactory.BackingInFavorDissalowed.selector);
        HUB_V2.safeTransferFrom(TEST_ACCOUNT_1, address(factory), uint256(uint160(TEST_ACCOUNT_2)), CRC_AMOUNT, "");
    }

    function test_RevertIf_OperatorIsNotBackingUser() public {
        vm.prank(TEST_ACCOUNT_1);
        // Grant approval for all tokens to test acccount 2
        HUB_V2.setApprovalForAll(TEST_ACCOUNT_2, true);

        vm.prank(TEST_ACCOUNT_2);
        vm.expectRevert(CirclesBackingFactory.BackingInFavorDissalowed.selector);
        // Transfer should fail because testAccount is not the operator
        HUB_V2.safeTransferFrom(TEST_ACCOUNT_1, address(factory), uint256(uint160(TEST_ACCOUNT_1)), CRC_AMOUNT, "");
    }

    function test_RevertIf_OrderInitNotByFactory() public {
        // Setup user with CRC and backing
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, WETH);

        vm.expectRevert(CirclesBacking.OnlyFactory.selector);
        CirclesBacking(predictedInstance).initiateCowswapOrder(USDC, 0, "");
    }

    // -------------------------------------------------------------------------
    // CirclesBacking + LBP Creation & Release
    // -------------------------------------------------------------------------

    function test_CreateLBP() public {
        // Setup user with CRC and backing
        uint256 transferredUserCRCAmount = HUB_V2.balanceOf(TEST_ACCOUNT_1, uint256(uint160(TEST_ACCOUNT_1)));
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, WBTC);
        transferredUserCRCAmount -= HUB_V2.balanceOf(TEST_ACCOUNT_1, uint256(uint160(TEST_ACCOUNT_1)));

        assertEq(transferredUserCRCAmount, CRC_AMOUNT);
        // Simulate the CowSwap fill
        _simulateCowSwapFill(predictedInstance, WBTC, BACKING_ASSET_DEAL_AMOUNT);

        assertFalse(factory.isActiveLBP(TEST_ACCOUNT_1), "LBP should be inactive before initialization");
        // Create LBP
        _createLBP(predictedInstance);
        assertTrue(factory.isActiveLBP(TEST_ACCOUNT_1), "LBP should be active after initialization");

        // Check the Backing instance constants
        assertEq(CirclesBacking(predictedInstance).BACKER(), TEST_ACCOUNT_1);
        assertEq(CirclesBacking(predictedInstance).BACKING_ASSET(), WBTC);
        assertEq(CirclesBacking(predictedInstance).STABLE_CRC(), LIFT_ERC20.ensureERC20(TEST_ACCOUNT_1, uint8(1)));

        address lbp = CirclesBacking(predictedInstance).lbp();

        // `1e6` is a Balancer LP amount minted to zero address during the pool initialization
        assertEq(IERC20(lbp).balanceOf(predictedInstance), IERC20(lbp).totalSupply() - 1e6);
        assertEq(factory.backerOf(predictedInstance), TEST_ACCOUNT_1);

        // Check the state of the deployed pool
        assertTrue(ILBP(lbp).getSwapEnabled(), "Swapping within the created LBP is not enabled");
        assertEq(ILBP(lbp).getOwner(), predictedInstance);
        assertEq(ILBP(lbp).getSwapFeePercentage(), 0.01 ether);
    }

    function test_RevertIf_CreatesLBPWithDifferentBackingAsset() public {
        // Setup user with CRC and backing
        _initUserWithBackedCRC(TEST_ACCOUNT_1, GNO);

        // Create Backing contract for sDAI backed LBP pool
        bytes memory data = abi.encode(sDAI);
        vm.prank(TEST_ACCOUNT_1);
        vm.expectRevert(); // -> EvmError: CreateCollision
        HUB_V2.safeTransferFrom(TEST_ACCOUNT_1, address(factory), uint256(uint160(TEST_ACCOUNT_1)), CRC_AMOUNT, data);
    }

    function test_RevertIf_LiquidityAddedNotByOwner() public {
        // Setup user with CRC and backing
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, GNO);

        // Simulate the CowSwap fill
        _simulateCowSwapFill(predictedInstance, GNO, BACKING_ASSET_DEAL_AMOUNT);

        // Create LBP
        _createLBP(predictedInstance);

        address lbp = CirclesBacking(predictedInstance).lbp();
        bytes32 poolId = ILBP(lbp).getPoolId();
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(GNO);
        tokens[1] = IERC20(CirclesBacking(predictedInstance).STABLE_CRC());

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = BACKING_ASSET_DEAL_AMOUNT;
        amountsIn[1] = 0;
        bytes memory userData = abi.encode(ILBP.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, amountsIn);
        IVault.JoinPoolRequest memory request = IVault.JoinPoolRequest(tokens, amountsIn, userData, false);

        vm.prank(TEST_ACCOUNT_1);
        vm.expectRevert("BAL#328"); // BAL#328 stands for `CALLER_IS_NOT_LBP_OWNER`
        IVault(VAULT).joinPool(
            poolId,
            TEST_ACCOUNT_1, // sender
            TEST_ACCOUNT_1, // recipient
            request
        );
    }

    function test_RevertIf_LBPIsAlreadyCreated() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, sDAI);

        _simulateCowSwapFill(predictedInstance, sDAI, BACKING_ASSET_DEAL_AMOUNT);

        // Create LBP first time
        _createLBP(predictedInstance);
        assertTrue(factory.isActiveLBP(TEST_ACCOUNT_1), "LBP should be active after initialization");
        assertNotEq(CirclesBacking(predictedInstance).lbp(), address(0));

        // Try to create second time => revert
        vm.expectRevert(CirclesBacking.AlreadyCreated.selector);
        _createLBP(predictedInstance);
    }

    function test_RevertIf_InsufficientBackingAssetOnOrderContract() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, WETH);
        CirclesBacking circlesBackingInstance = CirclesBacking(predictedInstance);
        // We simulate that settlment is "filled" without transfering `BACKING_ASSET` to the instance
        bytes memory storedUid = circlesBackingInstance.storedOrderUid();
        bytes32 slot = keccak256(abi.encodePacked(storedUid, uint256(ORDER_FILLED_SLOT)));
        vm.store(COWSWAP_SETTLEMENT, slot, bytes32(uint256(BACKING_ASSET_DEAL_AMOUNT)));

        assertEq(circlesBackingInstance.BACKING_ASSET(), WETH);
        assertEq(IERC20(circlesBackingInstance.BACKING_ASSET()).balanceOf(address(circlesBackingInstance)), 0);
        // Attempt to create LBP => revert
        vm.expectRevert(CirclesBacking.InsufficientBackingAssetBalance.selector);
        _createLBP(predictedInstance);
    }

    function test_BalancerPoolTokensRelease() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, GNO);

        // Simulate fill
        _simulateCowSwapFill(predictedInstance, GNO, BACKING_ASSET_DEAL_AMOUNT);

        // Create LBP
        _createLBP(predictedInstance);
        assertTrue(factory.isActiveLBP(TEST_ACCOUNT_1), "LBP should be active after initialization");

        // Warp enough time so that release is possible
        vm.warp(block.timestamp + YEAR);

        address lbp = CirclesBacking(predictedInstance).lbp();
        uint256 frozenLPTokensAmount = IERC20(lbp).balanceOf(predictedInstance);

        // Release from backer
        vm.prank(TEST_ACCOUNT_1);
        CirclesBacking(predictedInstance).releaseBalancerPoolTokens(TEST_ACCOUNT_1);
        assertFalse(
            factory.isActiveLBP(TEST_ACCOUNT_1), "LBP should be inactive after tokens released from the contract"
        );

        assertEq(IERC20(lbp).balanceOf(predictedInstance), 0);
        assertEq(IERC20(lbp).balanceOf(TEST_ACCOUNT_1), frozenLPTokensAmount);
    }

    function test_GlobalBalancerPoolTokensRelease() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, sDAI);

        vm.prank(FACTORY_ADMIN);
        factory.setReleaseTimestamp(uint32(block.timestamp + YEAR));

        // Simulate fill
        _simulateCowSwapFill(predictedInstance, sDAI, BACKING_ASSET_DEAL_AMOUNT);

        vm.warp(block.timestamp + YEAR);
        // Create LBP
        _createLBP(predictedInstance);
        assertTrue(factory.isActiveLBP(TEST_ACCOUNT_1), "LBP should be active after initialization");

        // Warp enough time so that release is possible
        vm.warp(block.timestamp + 2 days);

        address lbp = CirclesBacking(predictedInstance).lbp();
        uint256 frozenLPTokensAmount = IERC20(lbp).balanceOf(predictedInstance);

        // Block timestamp is greater than global release time
        assertGt(block.timestamp, factory.releaseTimestamp());
        // Release time of the backing contract is greater than the global release time
        assertGt(CirclesBacking(predictedInstance).balancerPoolTokensUnlockTimestamp(), factory.releaseTimestamp());
        // Release from backer
        vm.prank(TEST_ACCOUNT_1);
        CirclesBacking(predictedInstance).releaseBalancerPoolTokens(TEST_ACCOUNT_1);

        assertFalse(
            factory.isActiveLBP(TEST_ACCOUNT_1), "LBP should be inactive after tokens released from the contract"
        );

        assertEq(IERC20(lbp).balanceOf(predictedInstance), 0);
        assertEq(IERC20(lbp).balanceOf(TEST_ACCOUNT_1), frozenLPTokensAmount);
    }

    function test_RevertIf_NotifyReleaseCalledByNonBackingContract() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, sDAI);

        // Simulate fill
        _simulateCowSwapFill(predictedInstance, sDAI, BACKING_ASSET_DEAL_AMOUNT);

        // Create LBP
        _createLBP(predictedInstance);

        vm.expectRevert(CirclesBackingFactory.OnlyCirclesBacking.selector);
        factory.notifyRelease(predictedInstance);
    }

    function test_RevertIf_ReleaseBalancerPoolDeadlineNotMet() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, GNO);

        // Simulate fill
        _simulateCowSwapFill(predictedInstance, GNO, BACKING_ASSET_DEAL_AMOUNT);

        // Create LBP
        _createLBP(predictedInstance);

        // Attempt to release too soon
        vm.prank(TEST_ACCOUNT_1);
        vm.expectRevert(
            abi.encodeWithSelector(CirclesBacking.TokensLockedUntilTimestamp.selector, block.timestamp + YEAR)
        );
        CirclesBacking(predictedInstance).releaseBalancerPoolTokens(TEST_ACCOUNT_1);
    }

    function test_RevertIf_NotBacker() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, WETH);

        // Simulate fill
        _simulateCowSwapFill(predictedInstance, WETH, BACKING_ASSET_DEAL_AMOUNT);

        // Create LBP
        _createLBP(predictedInstance);
        vm.warp(block.timestamp + YEAR);

        // Some random address tries to release
        vm.prank(address(0));
        vm.expectRevert(CirclesBacking.NotBacker.selector);
        CirclesBacking(predictedInstance).releaseBalancerPoolTokens(TEST_ACCOUNT_1);
    }

    function test_RevertIf_BackingAssetIsNotSupported() public {
        // Attempt to back with USDT, which is not supported in the factory
        bytes memory data = abi.encode(USDT);
        vm.prank(TEST_ACCOUNT_1);
        vm.expectRevert(abi.encodeWithSelector(CirclesBackingFactory.UnsupportedBackingAsset.selector, USDT));
        HUB_V2.safeTransferFrom(TEST_ACCOUNT_1, address(factory), uint256(uint160(TEST_ACCOUNT_1)), CRC_AMOUNT, data);
    }

    function test_RevertIf_CreateLBPCalledByNonBackingContract() public {
        vm.expectRevert(CirclesBackingFactory.OnlyCirclesBacking.selector);
        // Attempt to call createLBP from the factory with invalid arguments
        factory.createLBP(USDT, CRC_AMOUNT, USDC, 100 ether);
    }

    // -------------------------------------------------------------------------
    // LBP Exits
    // -------------------------------------------------------------------------

    function test_RevertIf_ExitNonDualAssetPool() public {
        IERC20[] memory tokens = new IERC20[](3);
        uint256[] memory weights = new uint256[](3);
        tokens[0] = IERC20(USDC);
        tokens[1] = IERC20(USDT);
        tokens[2] = IERC20(WETH);

        weights[0] = 0.3 ether;
        weights[1] = 0.3 ether;
        weights[2] = 0.4 ether;

        // Create a 3-token LBP externally (just for testing exitLBP)
        address lbp = LBP_FACTORY.create("TestPool", "TP", tokens, weights, 0.01 ether, msg.sender, true);

        // Put some LP tokens in testAccount
        deal(lbp, TEST_ACCOUNT_1, 1 ether);

        // Approve the factory
        vm.prank(TEST_ACCOUNT_1);
        IERC20(lbp).approve(address(factory), 1 ether);

        vm.prank(TEST_ACCOUNT_1);
        vm.expectRevert(CirclesBackingFactory.OnlyTwoTokenLBPSupported.selector);
        factory.exitLBP(lbp, 1 ether);
    }

    function test_ExitDualAssetPool() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, WBTC);
        _simulateCowSwapFill(predictedInstance, WBTC, BACKING_ASSET_DEAL_AMOUNT);
        _createLBP(predictedInstance);

        address lbp = CirclesBacking(predictedInstance).lbp();

        vm.warp(block.timestamp + YEAR);

        // Release from backer
        vm.prank(TEST_ACCOUNT_1);
        CirclesBacking(predictedInstance).releaseBalancerPoolTokens(TEST_ACCOUNT_1);
        assertFalse(
            factory.isActiveLBP(TEST_ACCOUNT_1), "LBP should be inactive after tokens released from the contract"
        );

        uint256 LPTokensAmount = IERC20(lbp).balanceOf(TEST_ACCOUNT_1);
        // Approve
        vm.prank(TEST_ACCOUNT_1);
        IERC20(lbp).approve(address(factory), LPTokensAmount);

        bytes32 poolId = ILBP(lbp).getPoolId();
        (IERC20[] memory tokens, uint256[] memory balances,) = IVault(VAULT).getPoolTokens(poolId);

        // Exit
        vm.prank(TEST_ACCOUNT_1);
        factory.exitLBP(lbp, LPTokensAmount);

        assertApproxEqAbs(tokens[0].balanceOf(TEST_ACCOUNT_1), balances[0], MAX_DELTA);
        assertApproxEqAbs(tokens[1].balanceOf(TEST_ACCOUNT_1), balances[1], MAX_DELTA);
    }

    function test_PartialExitDualAssetPool() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, WETH);
        _simulateCowSwapFill(predictedInstance, WETH, BACKING_ASSET_DEAL_AMOUNT);
        _createLBP(predictedInstance);

        address lbp = CirclesBacking(predictedInstance).lbp();
        vm.warp(block.timestamp + YEAR);
        // Release from backer
        vm.prank(TEST_ACCOUNT_1);
        CirclesBacking(predictedInstance).releaseBalancerPoolTokens(TEST_ACCOUNT_1);
        assertFalse(
            factory.isActiveLBP(TEST_ACCOUNT_1), "LBP should be inactive after tokens released from the contract"
        );

        uint256 LPTokensAmount = IERC20(lbp).balanceOf(TEST_ACCOUNT_1);
        // Approve
        vm.prank(TEST_ACCOUNT_1);
        IERC20(lbp).approve(address(factory), LPTokensAmount);

        bytes32 poolId = ILBP(lbp).getPoolId();

        // Exit
        vm.prank(TEST_ACCOUNT_1);
        factory.exitLBP(lbp, LPTokensAmount / 2);
        assertEq(LPTokensAmount / 2, IERC20(lbp).balanceOf(TEST_ACCOUNT_1));

        (IERC20[] memory tokens, uint256[] memory balances,) = IVault(VAULT).getPoolTokens(poolId);
        assertApproxEqAbs(tokens[0].balanceOf(TEST_ACCOUNT_1), balances[0], MAX_DELTA);
        assertApproxEqAbs(tokens[1].balanceOf(TEST_ACCOUNT_1), balances[1], MAX_DELTA);
    }

    // -------------------------------------------------------------------------
    // Order Fill / Reverts
    // -------------------------------------------------------------------------

    function test_RevertIf_OrderNotFilledYet() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, WETH);

        vm.expectRevert(CirclesBacking.OrderNotFilledYet.selector);
        _createLBP(predictedInstance);
    }

    function test_RevertIf_UserIsNotHuman() public {
        // Mock the HUB so that isHuman(avatar) returns false (e.g. avatar is group)
        address user = TEST_ACCOUNT_1;
        vm.mockCall(address(HUB_V2), abi.encodeWithSelector(HUB_V2.isHuman.selector, user), abi.encode(false));

        // Attempt to back with CRC => should revert with OnlyHumanAvatarsAreSupported
        deal(USDC, user, USDC_START_AMOUNT);
        vm.prank(user);
        IERC20(USDC).approve(address(factory), USDC_START_AMOUNT);

        bytes memory data = abi.encode(WETH);
        vm.prank(user);
        vm.expectRevert(CirclesBackingFactory.OnlyHumanAvatarsAreSupported.selector);
        HUB_V2.safeTransferFrom(user, address(factory), uint256(uint160(user)), CRC_AMOUNT, data);
    }

    // -------------------------------------------------------------------------
    // Public Getters
    // -------------------------------------------------------------------------

    function testFuzz_GetAppData(address any) public view {
        (string memory appDataString, bytes32 appDataHash) = CirclesBackingFactory(factory).getAppData(any);
        assertEq(keccak256(bytes(appDataString)), appDataHash);
    }

    function test_PersonalCirclesAccount() public {
        assertEq(LIFT_ERC20.ensureERC20(TEST_ACCOUNT_1, uint8(1)), factory.getPersonalCircles(TEST_ACCOUNT_1));
    }
}
