// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CirclesBacking} from "src/CirclesBacking.sol";
import {CirclesBackingOrder} from "src/CirclesBackingOrder.sol";
import {CirclesBackingFactory} from "src/CirclesBackingFactory.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {ILiftERC20} from "src/interfaces/ILiftERC20.sol";
import {INoProtocolFeeLiquidityBootstrappingPoolFactory} from "src/interfaces/ILBPFactory.sol";
import {ILBP} from "src/interfaces/ILBP.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";
import {GPv2Order} from "composable-cow/BaseConditionalOrder.sol";
import {IValueFactory} from "composable-cow/interfaces/IValueFactory.sol";
import {ValueFactory} from "src/ValueFactory.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {MockPriceFeed} from "./mock/MockPriceFeed.sol";

import {IAggregatorV3Interface} from "src/interfaces/IAggregatorV3Interface.sol";

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
    uint256 internal constant MAX_DELTA = 3e10;
    uint256 internal constant SWAP_FEE = 0.03 ether;

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

    address internal constant WBTC = 0x8e5bBbb09Ed1ebdE8674Cda39A0c169401db4252;
    address internal constant WETH = 0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1;
    address internal constant GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address internal constant sDAI = 0xaf204776c7245bF4147c2612BF6e5972Ee483701;

    address internal constant WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;

    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

    CirclesBackingFactory internal factory;
    address internal FACTORY_ADMIN = makeAddr("admin");
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

    MockERC20 mockToken;
    MockPriceFeed mockTokenPriceFeed;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        // Fork from Gnosis
        gnosisFork = vm.createFork(vm.envString("GNOSIS_RPC"));
        vm.selectFork(gnosisFork);
        vm.deal(FACTORY_ADMIN, 1 ether);

        // Deploy factory
        vm.prank(FACTORY_ADMIN);
        factory = new CirclesBackingFactory(FACTORY_ADMIN, 100);

        // Retrieve constants from factory
        VAULT = factory.VAULT();
        USDC = factory.USDC();
        CRC_AMOUNT = factory.CRC_AMOUNT();

        TODAY = HUB_V2.day(block.timestamp);

        _setMintTime(TEST_ACCOUNT_1);
        _setMintTime(TEST_ACCOUNT_2);
        _setCRCBalance(uint256(uint160(TEST_ACCOUNT_1)), TEST_ACCOUNT_1, TODAY, uint192(CRC_AMOUNT * 2));
        _setCRCBalance(uint256(uint160(TEST_ACCOUNT_2)), TEST_ACCOUNT_2, TODAY, uint192(CRC_AMOUNT * 2));

        mockToken = new MockERC20("MockToken", "MTKN", 18, 1 ether);
        mockTokenPriceFeed = new MockPriceFeed(18, "MockTokenPrice", 1, 10);
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

    // Sort tokens by address (ascending order)
    function _sortTokens(IERC20 tokenA, IERC20 tokenB) internal pure returns (IERC20, IERC20) {
        if (address(tokenA) < address(tokenB)) {
            return (tokenA, tokenB);
        }
        return (tokenB, tokenA);
    }

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
        factory.setSupportedBackingAssetStatus(WXDAI, true);
        assertEq(factory.supportedBackingAssets(WXDAI), true);
    }

    function test_SetSlippageBPS() public {
        vm.prank(FACTORY_ADMIN);
        uint256 newBPSvalue = 5000;
        factory.setSlippageBPS(newBPSvalue);

        uint256 currentValue = ValueFactory(factory.valueFactory()).slippageBPS();
        assertEq(currentValue, newBPSvalue);
    }
    // @todo check naming add description

    function test_SetSlippageBPSOutOfBoundaries() public {
        uint256 initialValue = ValueFactory(factory.valueFactory()).slippageBPS();

        vm.prank(FACTORY_ADMIN);
        uint256 newBPSvalue = 15000;
        factory.setSlippageBPS(newBPSvalue); // @audit repot that the function is silent

        uint256 currentValue = ValueFactory(factory.valueFactory()).slippageBPS();
        assertNotEq(newBPSvalue, currentValue);
        assertEq(initialValue, currentValue);
    }

    function test_RevertIf_SetSlippageBPSDirectly() public {
        ValueFactory oracleFactoryAddress = factory.valueFactory();
        vm.expectRevert(ValueFactory.OnlyBackingFactory.selector);
        ValueFactory(oracleFactoryAddress).setSlippageBPS(100);
    }

    function test_SetOraclePriceFeed() public {
        vm.prank(FACTORY_ADMIN);
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));
    }
    // @todo `setOracle` price feed

    function test_RevertIf_NotAdminSetOraclePriceFeed() public {
        //IERC20 mockToken = IERC20(makeAddr("mockTokenAddress"));
        //ValueFactory oracleFactoryAddress = factory.valueFactory();
        vm.expectRevert(CirclesBackingFactory.OnlyAdmin.selector);
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));
    }
    // @todo check

    function test_ReverIf_SetOraclePriceFeedNotByFactory() public {
        ValueFactory oracleFactoryAddress = factory.valueFactory();
        vm.expectRevert(ValueFactory.OnlyBackingFactory.selector);
        oracleFactoryAddress.setOracle(address(mockToken), address(mockTokenPriceFeed));
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
        // Grant approval for all tokens to test acccount 2
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

        // @todo check the order
        //address owner, address buyToken, uint256 buyAmount, uint32 validTo, bytes32 appData
        //factory.getOrder()

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
        // We simulate that settlment is "filled" without transfering `BACKING_ASSET` to the instance
        // @todo double check if we need it
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
        // @todo doublecheck why we need such a  huge delta
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
    // Oracles settings
    // -------------------------------------------------------------------------

    function test_GetOraclePrices() public view {
        ValueFactory valueFactory = factory.valueFactory();
        uint256 priceUint256 = ValueFactory(valueFactory).getValue(USDC);
        bytes32 priceBytes32 = ValueFactory(valueFactory).getValue(abi.encode(USDC));
        assertEq(priceUint256, uint256(priceBytes32));
    }

    function test_OraclePricesForTokenWithFewDecimals() public {
        uint8 DECIMALS = 1;
        int256 TEST_PRICE = 10_000; // $1000.0 with 1 decimal
        mockTokenPriceFeed = new MockPriceFeed(DECIMALS, "MockTokenPrice", 1, TEST_PRICE);

        vm.prank(FACTORY_ADMIN);
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));
        ValueFactory valueFactory = factory.valueFactory();
        uint256 tokenAmount = valueFactory.getValue(address(mockToken));

        // Verify we get a positive amount with valid price
        assertGt(tokenAmount, 1, "Token amount should be positive with valid price");
    }

    function test_OraclePriceUpdateAffectsTokenAmount() public {
        // Setup
        uint8 DECIMALS = 1;
        int256 INITIAL_PRICE = 10_000; // $1000.0 with 1 decimal
        mockTokenPriceFeed = new MockPriceFeed(DECIMALS, "MockTokenPrice", 1, INITIAL_PRICE);

        vm.prank(FACTORY_ADMIN);
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));
        ValueFactory valueFactory = factory.valueFactory();
        uint256 initialAmount = valueFactory.getValue(address(mockToken));

        // Test price update - higher price should result in lower token amount
        int256 DOUBLED_PRICE = 20_000; // $2000.0 with 1 decimal
        mockTokenPriceFeed.updateAnswer(DOUBLED_PRICE);
        uint256 newAmount = valueFactory.getValue(address(mockToken));

        assertLt(newAmount, initialAmount, "Higher price should result in lower token amount");
        // It should be roughly half the amount since we doubled the price
        assertApproxEqRel(newAmount, initialAmount / 2, 0.01e18, "Amount should be approximately halved");
    }

    function test_OracleStalePriceDataHandling() public {
        // Setup
        uint8 DECIMALS = 1;
        int256 TEST_PRICE = 10_000;
        mockTokenPriceFeed = new MockPriceFeed(DECIMALS, "MockTokenPrice", 1, TEST_PRICE);

        vm.prank(FACTORY_ADMIN);
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));
        ValueFactory valueFactory = factory.valueFactory();

        mockTokenPriceFeed.updateAnswer(TEST_PRICE);
        // Test with stale price data (more than 1 day old)
        uint256 staleTimestamp = block.timestamp + 2 days;
        vm.warp(staleTimestamp);

        uint256 staleAmount = valueFactory.getValue(address(mockToken));
        assertEq(staleAmount, 1, "Stale price data should return minimal amount of 1");
    }

    function test_OracleZeroPriceHandling() public {
        // Setup
        uint8 DECIMALS = 1;
        int256 TEST_PRICE = 10_000;
        mockTokenPriceFeed = new MockPriceFeed(DECIMALS, "MockTokenPrice", 1, TEST_PRICE);

        vm.prank(FACTORY_ADMIN);
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));
        ValueFactory valueFactory = factory.valueFactory();

        // First check with valid price
        uint256 validAmount = valueFactory.getValue(address(mockToken));
        assertGt(validAmount, 1, "Valid price should return more than minimal amount");

        // Test with zero price
        mockTokenPriceFeed.updateAnswer(0);
        uint256 zeroAmount = valueFactory.getValue(address(mockToken));
        assertEq(zeroAmount, 1, "Zero price should return minimal amount of 1");
    }

    function testFuzz_OracleSlippageImpactAcrossDecimalRanges(uint8 fuzzedDecimals) public {
        // Constrain decimals to a realistic range (1-20)
        uint8 oracleDecimals = uint8(bound(fuzzedDecimals, 1, 20));

        // Setup with a token that has few decimals
        int256 TEST_PRICE = 1_000 * int256(10 ** oracleDecimals);
        mockTokenPriceFeed = new MockPriceFeed(oracleDecimals, "MockTokenPrice", 1, TEST_PRICE);

        // Constants from the ValueFactory contract
        uint256 MAX_BPS = 10000; // 100% in basis points (from ValueFactory contract)
        uint256 DEFAULT_SLIPPAGE_BPS = 500; // Default 5% slippage

        vm.prank(FACTORY_ADMIN);
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));
        ValueFactory valueFactory = factory.valueFactory();

        // Verify the default slippage matches what we expect
        assertEq(valueFactory.slippageBPS(), DEFAULT_SLIPPAGE_BPS, "Initial slippage should be 500 BPS (5%)");

        // Get token amount with default slippage
        uint256 defaultSlippageAmount = valueFactory.getValue(address(mockToken));

        // Change slippage to 10%
        uint256 NEW_SLIPPAGE_BPS = 1000; // 10% slippage
        vm.prank(FACTORY_ADMIN);
        factory.setSlippageBPS(NEW_SLIPPAGE_BPS);

        // Verify slippage was updated correctly
        assertEq(valueFactory.slippageBPS(), NEW_SLIPPAGE_BPS, "Slippage should be updated to 1000 BPS (10%)");

        // Get token amount with increased slippage
        uint256 higherSlippageAmount = valueFactory.getValue(address(mockToken));

        // Basic check: higher slippage should result in lower token amount
        assertLt(higherSlippageAmount, defaultSlippageAmount, "Higher slippage should result in lower buy amount");

        // Calculate the expected ratio between amounts with different slippages
        // From the ValueFactory contract:
        //   buyAmount = (buyAmount * (MAX_BPS - slippageBPS)) / MAX_BPS;
        //
        // With default 5% slippage: effective multiplier = (10000 - 500)/10000 = 0.95
        // With new 10% slippage: effective multiplier = (10000 - 1000)/10000 = 0.90
        //
        // Expected ratio = 0.90 / 0.95 = 0.947... (approximately 94.7%)
        // In basis points: (9000 * 10000) / 9500 = 9474 BPS
        uint256 expectedRatio = (MAX_BPS - NEW_SLIPPAGE_BPS) * MAX_BPS / (MAX_BPS - DEFAULT_SLIPPAGE_BPS);
        uint256 actualRatio = higherSlippageAmount * MAX_BPS / defaultSlippageAmount;
        //console.log(actualRatio, expectedRatio);
        // Check that the ratio is as expected (with a small tolerance for rounding errors)
        assertEq(actualRatio, expectedRatio, "Slippage impact should the expected ratio");
    }

    // @notice division by zero error
    function test_RevertIf_OraclePriceIsVeryLow() public {
        // Setup a token with high decimals (greater than 8)
        uint8 ORACLE_DECIMALS = 9;

        // Create a price feed with an extremely low price - just 1 unit
        // This is equivalent to $0.00000001 for an 8-decimal oracle
        int256 EXTREMELY_LOW_PRICE = 1;

        mockTokenPriceFeed = new MockPriceFeed(ORACLE_DECIMALS, "LowPriceFeed", 1, EXTREMELY_LOW_PRICE);

        // Set the oracles
        vm.startPrank(FACTORY_ADMIN);
        // Then set our test token's oracle
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));

        ValueFactory valueFactory = factory.valueFactory();

        // Issue: When a token has an extremely low price and high decimals, the `_scalePrice`
        // function can scale the price down to zero due to integer division in Solidity.
        //
        // Since the contract only checks for zero prices BEFORE scaling (not after), this creates
        // a division by zero error in the calculation:
        // `buyAmount = (buyUnit * basePrice * SELL_AMOUNT) / (quotePrice * SELL_UNIT)`

        // Specifically:
        // 1. A token with 9 decimals having a price of 1 (0.000000001)
        // 2. When scaled from 9 to 8 decimals: 1 / 10 = 0 (in integer math)
        // 3. This leads to division by zero when calculating the buy amount

        // Proposed fix: Add a safety check for zero AFTER scaling the prices:
        //  - After `quotePrice = _scalePrice(quotePrice, buyOracle.feedDecimals, 8);`
        //  - Add: `if (quotePrice == 0) { buyAmount = 1; } else { ... }`

        // Check if the function reverts due to division by zero
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x12));
        uint256 amount = valueFactory.getValue(address(mockToken));

        // @todo uncomment after the fix
        // assertEq(amount, 1, "Low price should return minimal amount of 1");
    }

    function test_OracleRemovePriceFeed() public {
        ValueFactory valueFactory = factory.valueFactory();

        vm.prank(FACTORY_ADMIN);
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));

        (IAggregatorV3Interface priceFeedAddress, uint8 feedDecimals, uint8 tokenDecimals) =
            valueFactory.oracles(address(mockToken));
        // Price feed was added correctly
        assertEq(address(priceFeedAddress), address(mockTokenPriceFeed));
        assertEq(feedDecimals, mockTokenPriceFeed.decimals());
        assertEq(tokenDecimals, mockToken.decimals());

        vm.prank(FACTORY_ADMIN);
        factory.setOracle(address(mockToken), address(0));
        (priceFeedAddress, feedDecimals, tokenDecimals) = valueFactory.oracles(address(mockToken));
        assertEq(address(priceFeedAddress), address(0));
        assertEq(feedDecimals, 0);
        assertEq(tokenDecimals, 0);
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

        // Oracle price changed after initial order creation which allows resseting the order
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

    function test_RevertIf_ResettingNewrlyCreatedOrder() public {
        // Setup user with CRC and backing
        uint256 transferredUserCRCAmount = HUB_V2.balanceOf(TEST_ACCOUNT_1, uint256(uint160(TEST_ACCOUNT_1)));
        address predictedInstance = _initUserWithBackedCRC(TEST_ACCOUNT_1, WBTC);
        transferredUserCRCAmount -= HUB_V2.balanceOf(TEST_ACCOUNT_1, uint256(uint160(TEST_ACCOUNT_1)));

        assertEq(transferredUserCRCAmount, CRC_AMOUNT);

        vm.expectRevert(CirclesBacking.OrderUidIsTheSame.selector);
        CirclesBacking(predictedInstance).resetCowswapOrder();
    }
    // @todo update naming

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
