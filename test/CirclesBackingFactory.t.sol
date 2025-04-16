// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";
import {GPv2Order} from "composable-cow/BaseConditionalOrder.sol";

import {CirclesBacking} from "src/CirclesBacking.sol";
import {CirclesBackingOrder} from "src/CirclesBackingOrder.sol";
import {CirclesBackingFactory} from "src/CirclesBackingFactory.sol";
import {ILBP} from "src/interfaces/ILBP.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {BaseTestContract} from "test/helpers/BaseTestContract.sol";

/**
 * @title CirclesBackingFactoryTest
 * @notice Foundry test suite for CirclesBackingFactory and the CirclesBacking instances.
 */
contract CirclesBackingFactoryTest is Test, BaseTestContract {
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
        factory.setSupportedBackingAssetStatus(WXDAI, true);
        assertEq(factory.supportedBackingAssets(WXDAI), true);
    }

    function test_DisableBackingAssetSupport() public {
        vm.prank(FACTORY_ADMIN);
        factory.setSupportedBackingAssetStatus(WBTC, false);
        assertEq(factory.supportedBackingAssets(WBTC), false);
    }

    function test_RevertIf_UserSetSupportedBackingAssetStatus() public {
        vm.expectRevert(CirclesBackingFactory.OnlyAdmin.selector);
        factory.setSupportedBackingAssetStatus(WXDAI, false);
    }

    function test_RevertIf_UserSetsReleaseTime() public {
        vm.expectRevert(CirclesBackingFactory.OnlyAdmin.selector);
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
        // Transfer some personal CRC from testAccount2 -> testAccount1
        HUB_V2.safeTransferFrom(TEST_ACCOUNT_2, TEST_ACCOUNT_1, uint256(uint160(TEST_ACCOUNT_2)), CRC_AMOUNT, "");

        // Attempt to back testAccount2's CRC from testAccount1 -> factory
        vm.prank(TEST_ACCOUNT_1);
        vm.expectRevert(CirclesBackingFactory.BackingInFavorDisallowed.selector);
        HUB_V2.safeTransferFrom(TEST_ACCOUNT_1, address(factory), uint256(uint160(TEST_ACCOUNT_2)), CRC_AMOUNT, "");
    }

    function test_RevertIf_OperatorIsNotBackingUser() public {
        vm.prank(TEST_ACCOUNT_1);
        // Grant approval for all tokens to test account 2
        HUB_V2.setApprovalForAll(TEST_ACCOUNT_2, true);

        vm.prank(TEST_ACCOUNT_2);
        vm.expectRevert(CirclesBackingFactory.BackingInFavorDisallowed.selector);
        // Transfer should fail because testAccount1 is not the operator
        HUB_V2.safeTransferFrom(TEST_ACCOUNT_1, address(factory), uint256(uint160(TEST_ACCOUNT_1)), CRC_AMOUNT, "");
    }

    function test_RevertIf_OrderInitNotByFactory() public {
        // Setup user with CRC and backing
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, WETH);

        IConditionalOrder.ConditionalOrderParams memory mockParams = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(makeAddr("mockAddress")),
            salt: bytes32("mock salt"),
            staticInput: abi.encode("mock data")
        });

        vm.expectRevert(CirclesBacking.CallerNotFactory.selector);
        CirclesBacking(predictedInstance).initiateCowswapOrder(uint256(bytes32("mock num")), mockParams, "");
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

        assertEq(ILBP(lbp).getSwapFeePercentage(), SWAP_FEE);
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
        uint256 backingAssetDealAmount = CirclesBacking(predictedInstance).buyAmount();
        _simulateCowSwapFill(predictedInstance, GNO, backingAssetDealAmount);

        // Create LBP
        _createLBP(predictedInstance);

        address lbp = CirclesBacking(predictedInstance).lbp();
        bytes32 poolId = ILBP(lbp).getPoolId();
        IERC20[] memory tokens = new IERC20[](2);
        (tokens[0], tokens[1]) = _sortTokens(IERC20(CirclesBacking(predictedInstance).STABLE_CRC()), IERC20(GNO));

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = backingAssetDealAmount;
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

        uint256 backingAssetDealAmount = CirclesBacking(predictedInstance).buyAmount();
        _simulateCowSwapFill(predictedInstance, sDAI, backingAssetDealAmount);

        // Create LBP first time
        _createLBP(predictedInstance);
        assertTrue(factory.isActiveLBP(TEST_ACCOUNT_1), "LBP should be active after initialization");
        assertNotEq(CirclesBacking(predictedInstance).lbp(), address(0));

        // Try to create second time => revert
        vm.expectRevert(CirclesBacking.LBPAlreadyCreated.selector);
        _createLBP(predictedInstance);
    }

    function test_RevertIf_InsufficientBackingAssetOnOrderContract() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, WETH);
        CirclesBacking circlesBackingInstance = CirclesBacking(predictedInstance);

        uint256 backingAssetDealAmount = CirclesBacking(predictedInstance).buyAmount();
        // We simulate that settlement is "filled" without transferring `BACKING_ASSET` to the instance
        bytes memory storedUid = circlesBackingInstance.storedOrderUid();
        bytes32 slot = keccak256(abi.encodePacked(storedUid, uint256(ORDER_FILLED_SLOT)));
        vm.store(COWSWAP_SETTLEMENT, slot, bytes32(uint256(backingAssetDealAmount)));

        assertEq(circlesBackingInstance.BACKING_ASSET(), WETH);
        assertEq(IERC20(circlesBackingInstance.BACKING_ASSET()).balanceOf(address(circlesBackingInstance)), 0);
        // Attempt to create LBP => revert
        vm.expectRevert(
            abi.encodeWithSelector(CirclesBacking.BackingAssetBalanceInsufficient.selector, 0, backingAssetDealAmount)
        );
        _createLBP(predictedInstance);
    }

    function test_BalancerPoolTokensRelease() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, GNO);

        // Simulate fill
        uint256 backingAssetDealAmount = CirclesBacking(predictedInstance).buyAmount();
        _simulateCowSwapFill(predictedInstance, GNO, backingAssetDealAmount);

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
        // Simulate fill
        uint256 backingAssetDealAmount = CirclesBacking(predictedInstance).buyAmount();
        _simulateCowSwapFill(predictedInstance, sDAI, backingAssetDealAmount);
        // Create LBP
        _createLBP(predictedInstance);
        assertTrue(factory.isActiveLBP(TEST_ACCOUNT_1), "LBP should be active after initialization");

        vm.prank(FACTORY_ADMIN);
        factory.setReleaseTimestamp(uint32(block.timestamp));

        // Block timestamp is equal global release time
        assertEq(block.timestamp, factory.releaseTimestamp());

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

    function test_RevertIf_NotifyReleaseCalledByNonBackingContract() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, sDAI);

        // Simulate fill
        uint256 backingAssetDealAmount = CirclesBacking(predictedInstance).buyAmount();
        _simulateCowSwapFill(predictedInstance, sDAI, backingAssetDealAmount);

        // Create LBP
        _createLBP(predictedInstance);

        vm.expectRevert(CirclesBackingFactory.OnlyCirclesBacking.selector);
        factory.notifyRelease(predictedInstance);
    }

    function test_RevertIf_ReleaseBalancerPoolDeadlineNotMet() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, GNO);

        // Simulate fill
        uint256 backingAssetDealAmount = CirclesBacking(predictedInstance).buyAmount();
        _simulateCowSwapFill(predictedInstance, GNO, backingAssetDealAmount);

        // Create LBP
        _createLBP(predictedInstance);

        // Attempt to release too soon
        vm.prank(TEST_ACCOUNT_1);
        vm.expectRevert(
            abi.encodeWithSelector(CirclesBacking.BalancerPoolTokensLockedUntil.selector, block.timestamp + YEAR)
        );
        CirclesBacking(predictedInstance).releaseBalancerPoolTokens(TEST_ACCOUNT_1);
    }

    function test_RevertIf_NotBacker() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, WETH);

        // Simulate fill
        uint256 backingAssetDealAmount = CirclesBacking(predictedInstance).buyAmount();
        _simulateCowSwapFill(predictedInstance, WETH, backingAssetDealAmount);

        // Create LBP
        _createLBP(predictedInstance);
        vm.warp(block.timestamp + YEAR);

        // Some random address tries to release
        vm.prank(address(0));
        vm.expectRevert(CirclesBacking.CallerNotBacker.selector);
        CirclesBacking(predictedInstance).releaseBalancerPoolTokens(TEST_ACCOUNT_1);
    }

    function test_RevertIf_BackingAssetIsNotSupported() public {
        // Attempt to back with WXDAI, which is not supported in the factory
        bytes memory data = abi.encode(WXDAI);
        vm.prank(TEST_ACCOUNT_1);
        vm.expectRevert(abi.encodeWithSelector(CirclesBackingFactory.UnsupportedBackingAsset.selector, WXDAI));
        HUB_V2.safeTransferFrom(TEST_ACCOUNT_1, address(factory), uint256(uint160(TEST_ACCOUNT_1)), CRC_AMOUNT, data);
    }

    function test_RevertIf_CreateLBPCalledByNonBackingContract() public {
        vm.expectRevert(CirclesBackingFactory.OnlyCirclesBacking.selector);
        // Attempt to call createLBP from the factory with invalid arguments
        factory.createLBP(WXDAI, CRC_AMOUNT, USDC, 100 ether);
    }

    // -------------------------------------------------------------------------
    // LBP Exits
    // -------------------------------------------------------------------------

    function test_RevertIf_ExitNonDualAssetPool() public {
        IERC20[] memory tokens = new IERC20[](3);
        uint256[] memory weights = new uint256[](3);
        tokens[0] = IERC20(USDC);
        tokens[1] = IERC20(WETH);
        tokens[2] = IERC20(WXDAI);

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
        factory.exitLBP(lbp, 1 ether, 0, 0);
    }

    function test_ExitDualAssetPool() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, WBTC);
        uint256 backingAssetDealAmount = CirclesBacking(predictedInstance).buyAmount();
        _simulateCowSwapFill(predictedInstance, WBTC, backingAssetDealAmount);
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
        factory.exitLBP(lbp, LPTokensAmount, 0, 0);

        assertApproxEqAbs(tokens[0].balanceOf(TEST_ACCOUNT_1), balances[0], MAX_DELTA);
        assertApproxEqAbs(tokens[1].balanceOf(TEST_ACCOUNT_1), balances[1], MAX_DELTA);
    }

    function test_PartialExitDualAssetPool() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, WETH);
        uint256 backingAssetDealAmount = CirclesBacking(predictedInstance).buyAmount();
        _simulateCowSwapFill(predictedInstance, WETH, backingAssetDealAmount);
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
        factory.exitLBP(lbp, LPTokensAmount / 2, 0, 0);
        assertEq(LPTokensAmount / 2, IERC20(lbp).balanceOf(TEST_ACCOUNT_1));

        (IERC20[] memory tokens, uint256[] memory balances,) = IVault(VAULT).getPoolTokens(poolId);
        assertApproxEqAbs(tokens[0].balanceOf(TEST_ACCOUNT_1), balances[0], MAX_DELTA);
        assertApproxEqAbs(tokens[1].balanceOf(TEST_ACCOUNT_1), balances[1], MAX_DELTA);
    }

    // -------------------------------------------------------------------------
    // CowSwap Orders Logic & Validation
    // -------------------------------------------------------------------------

    function test_ResetCowswapOrder() public {
        // Setup Oracle for custom mock token
        vm.prank(FACTORY_ADMIN);
        factory.setSupportedBackingAssetStatus(address(mockToken), true);
        vm.prank(FACTORY_ADMIN);
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));

        mockTokenPriceFeed.updateAnswer(0.5 ether);
        // Setup user with CRC and backing
        uint256 transferredUserCRCAmount = HUB_V2.balanceOf(TEST_ACCOUNT_1, uint256(uint160(TEST_ACCOUNT_1)));
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, address(mockToken));
        transferredUserCRCAmount -= HUB_V2.balanceOf(TEST_ACCOUNT_1, uint256(uint160(TEST_ACCOUNT_1)));
        assertEq(transferredUserCRCAmount, CRC_AMOUNT);

        // Oracle price changed after initial order creation which allows resetting the order
        mockTokenPriceFeed.updateAnswer(0.1 ether);
        CirclesBacking(predictedInstance).resetCowswapOrder();
    }

    function test_FactoryGetOrderFunction() public view {
        // Parameters for testing
        address owner = TEST_ACCOUNT_1;
        address buyToken = WETH;
        uint256 buyAmount = 1 ether;
        uint32 validTo = uint32(block.timestamp + 1 days);
        bytes32 appData = bytes32("test app data");

        // Get the order
        GPv2Order.Data memory orderData = factory.getOrder(owner, buyToken, buyAmount, validTo, appData);

        // Verify all fields of the returned order
        assertEq(address(orderData.sellToken), USDC);
        assertEq(address(orderData.buyToken), WETH);
        assertEq(orderData.receiver, owner);
        assertEq(orderData.sellAmount, factory.TRADE_AMOUNT());
        assertEq(orderData.buyAmount, buyAmount);
        assertEq(orderData.validTo, validTo);
        assertEq(orderData.appData, appData);
        assertEq(orderData.feeAmount, 0);
        assertEq(orderData.kind, GPv2Order.KIND_SELL);
        assertFalse(orderData.partiallyFillable);
        assertEq(orderData.sellTokenBalance, GPv2Order.BALANCE_ERC20);
        assertEq(orderData.buyTokenBalance, GPv2Order.BALANCE_ERC20);
    }

    function test_GetConditionalParamsAndOrderUid() public view {
        // Parameters for testing
        address owner = TEST_ACCOUNT_1;
        address backingAsset = WETH;
        uint32 orderDeadline = uint32(block.timestamp + 1 days);
        (, bytes32 appData) = factory.getAppData(owner);
        uint256 nonce = 123;

        // Get parameters and order UID
        (uint256 buyAmount, IConditionalOrder.ConditionalOrderParams memory params, bytes memory orderUid) =
            factory.getConditionalParamsAndOrderUid(owner, backingAsset, orderDeadline, appData, nonce);

        // Verify buyAmount is calculated correctly via valueFactory
        assertEq(buyAmount, factory.valueFactory().getValue(backingAsset));

        // Verify params
        assertEq(address(params.handler), address(factory.circlesBackingOrder()));
        assertEq(params.salt, keccak256(abi.encode(owner, nonce)));

        // Decode static input from params
        CirclesBackingOrder.OrderStaticInput memory staticInput =
            abi.decode(params.staticInput, (CirclesBackingOrder.OrderStaticInput));

        // Verify static input
        assertEq(staticInput.buyToken, backingAsset);
        assertEq(staticInput.buyAmount, buyAmount);
        assertEq(staticInput.validTo, orderDeadline);
        assertEq(staticInput.appData, appData);

        // Verify orderUid structure
        GPv2Order.Data memory order = factory.getOrder(owner, backingAsset, buyAmount, orderDeadline, appData);
        bytes32 digest = GPv2Order.hash(order, factory.DOMAIN_SEPARATOR());
        bytes memory expectedOrderUid = abi.encodePacked(digest, owner, orderDeadline);
        assertEq(orderUid, expectedOrderUid);
    }

    function test_GetTradeableOrderWithValidInput() public {
        // Setup to avoid 'balance insufficient' error
        deal(USDC, TEST_ACCOUNT_1, factory.TRADE_AMOUNT());

        CirclesBackingOrder order = factory.circlesBackingOrder();

        // Prepare valid static input
        uint32 validTo = uint32(block.timestamp + 1 days);
        CirclesBackingOrder.OrderStaticInput memory staticInput =
            CirclesBackingOrder.OrderStaticInput(WETH, 1 ether, validTo, bytes32("test app data"));

        // Should not revert with valid parameters
        GPv2Order.Data memory orderData =
            order.getTradeableOrder(TEST_ACCOUNT_1, address(0), bytes32(""), abi.encode(staticInput), bytes(""));

        // Verify results
        assertEq(address(orderData.buyToken), WETH);
        assertEq(orderData.buyAmount, 1 ether);
        assertEq(orderData.validTo, validTo);
    }

    function test_RevertIf_ResettingSettledOrder() public {
        // Setup user with CRC and backing
        uint256 transferredUserCRCAmount = HUB_V2.balanceOf(TEST_ACCOUNT_1, uint256(uint160(TEST_ACCOUNT_1)));
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, WBTC);
        transferredUserCRCAmount -= HUB_V2.balanceOf(TEST_ACCOUNT_1, uint256(uint160(TEST_ACCOUNT_1)));

        assertEq(transferredUserCRCAmount, CRC_AMOUNT);

        _simulateCowSwapFill(predictedInstance, WBTC, BACKING_ASSET_DEAL_AMOUNT);

        vm.expectRevert(CirclesBacking.OrderAlreadySettled.selector);
        CirclesBacking(predictedInstance).resetCowswapOrder();
    }

    function test_RevertIf_ResettingNewlyCreatedOrder() public {
        // Setup user with CRC and backing
        uint256 transferredUserCRCAmount = HUB_V2.balanceOf(TEST_ACCOUNT_1, uint256(uint160(TEST_ACCOUNT_1)));
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, WBTC);
        transferredUserCRCAmount -= HUB_V2.balanceOf(TEST_ACCOUNT_1, uint256(uint160(TEST_ACCOUNT_1)));

        assertEq(transferredUserCRCAmount, CRC_AMOUNT);

        vm.expectRevert(CirclesBacking.OrderUidIsTheSame.selector);
        CirclesBacking(predictedInstance).resetCowswapOrder();
    }

    function test_RevertIf_CreatingOrderWithInsufficientBalance() public {
        // Setup
        CirclesBackingOrder circlesBackingOrder = factory.circlesBackingOrder();

        // Explicitly verify the balance is zero before test
        assertEq(IERC20(USDC).balanceOf(TEST_ACCOUNT_1), 0, "Balance should be zero for this test");

        CirclesBackingOrder.OrderStaticInput memory staticInput =
            CirclesBackingOrder.OrderStaticInput(WETH, 1 ether, uint32(block.timestamp + 100), bytes32(""));

        // Expect revert due to insufficient balance
        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, "balance insufficient"));

        circlesBackingOrder.getTradeableOrder(
            TEST_ACCOUNT_1, address(0x0), bytes32(""), abi.encode(staticInput), bytes("")
        );

        // Test with almost enough balance but still insufficient
        uint256 almostEnough = factory.TRADE_AMOUNT() - 1;
        deal(USDC, TEST_ACCOUNT_1, almostEnough);

        assertEq(IERC20(USDC).balanceOf(TEST_ACCOUNT_1), almostEnough, "Balance should be almost enough");

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, "balance insufficient"));

        circlesBackingOrder.getTradeableOrder(
            TEST_ACCOUNT_1, address(0x0), bytes32(""), abi.encode(staticInput), bytes("")
        );

        // Test with sufficient balance
        deal(USDC, TEST_ACCOUNT_1, factory.TRADE_AMOUNT());

        assertGe(IERC20(USDC).balanceOf(TEST_ACCOUNT_1), factory.TRADE_AMOUNT(), "Balance should be enough");

        circlesBackingOrder.getTradeableOrder(
            TEST_ACCOUNT_1, address(0x0), bytes32(""), abi.encode(staticInput), bytes("")
        );
    }

    function test_RevertIf_CreatingOrderWithUnsupportedAsset() public {
        // Setup
        address randomAsset = makeAddr("randomUnsupportedAsset");

        // Explicitly verify the asset is not supported before test
        assertFalse(factory.supportedBackingAssets(randomAsset), "Asset should not be supported for this test");

        // Ensure account has sufficient balance of the sell token
        deal(USDC, TEST_ACCOUNT_1, 1 ether);

        CirclesBackingOrder.OrderStaticInput memory staticInput =
            CirclesBackingOrder.OrderStaticInput(randomAsset, 1000, uint32(block.timestamp), bytes32(""));

        CirclesBackingOrder circlesBackingOrder = factory.circlesBackingOrder();
        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, "asset unsupported"));

        CirclesBackingOrder(circlesBackingOrder).getTradeableOrder(
            TEST_ACCOUNT_1, address(0x0), bytes32(""), abi.encode(staticInput), bytes("")
        );
    }

    function test_RevertIf_OrderExpired() public {
        deal(USDC, TEST_ACCOUNT_1, USDC_START_AMOUNT);

        // Just expired (1 second ago)
        CirclesBackingOrder.OrderStaticInput memory staticInput =
            CirclesBackingOrder.OrderStaticInput(WETH, 10000, uint32(block.timestamp - 1), bytes32(""));

        CirclesBackingOrder circlesBackingOrder = factory.circlesBackingOrder();

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, "order expired"));

        CirclesBackingOrder(circlesBackingOrder).getTradeableOrder(
            TEST_ACCOUNT_1, address(0x0), bytes32(""), abi.encode(staticInput), bytes("")
        );
    }

    function test_RevertIf_OrderNotFilledYet() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, WETH);

        vm.expectRevert(CirclesBacking.OrderNotYetFilled.selector);
        _createLBP(predictedInstance);
    }

    // solution state: proposal
    function test_HandleOrderFailureCreateLBPBackedWithUSDC() public {
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, WETH);
        // pass 1 day
        vm.warp(block.timestamp + 1 days + 1);
        // deploys LBP with USDC instead of backing asset
        _createLBP(predictedInstance);
        address lbp = CirclesBacking(predictedInstance).lbp();

        // `1e6` is a Balancer LP amount minted to zero address during the pool initialization
        assertEq(IERC20(lbp).balanceOf(predictedInstance), IERC20(lbp).totalSupply() - 1e6);
        assertEq(factory.backerOf(predictedInstance), TEST_ACCOUNT_1);

        // Check the state of the deployed pool
        assertTrue(ILBP(lbp).getSwapEnabled(), "Swapping within the created LBP is not enabled");
        assertEq(ILBP(lbp).getOwner(), predictedInstance);
        assertEq(ILBP(lbp).getSwapFeePercentage(), SWAP_FEE);
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
