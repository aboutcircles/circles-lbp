// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CirclesBacking} from "src/CirclesBacking.sol";
import {CirclesBackingFactory} from "src/CirclesBackingFactory.sol";
import {INoProtocolFeeLiquidityBootstrappingPoolFactory} from "src/interfaces/ILBPFactory.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {ILiftERC20} from "src/interfaces/ILiftERC20.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {MockPriceFeed} from "test/mock/MockPriceFeed.sol";

/**
 * @title BaseTestContract
 * @notice Helper contract for testing CirclesBacking
 * @dev Initialize this contract after deploying the factory to use its helper methods
 */
contract BaseTestContract is Test {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------
    uint256 public constant USDC_START_AMOUNT = 100e6; // 100 USDC
    uint256 public constant BACKING_ASSET_DEAL_AMOUNT = 0.03 ether;
    uint256 public constant YEAR = 365 days;
    uint256 public constant MAX_DELTA = 3e10;
    uint256 public constant SWAP_FEE = 0.03 ether;
    int256 public constant INITIAL_FEED_PRICE = 10 ether;

    // Storage slots
    uint256 public constant ORDER_FILLED_SLOT = 2;
    uint256 public constant DISCOUNTED_BALANCES_SLOT = 17;
    uint256 public constant MINT_TIMES_SLOT = 21;

    // Standard addresses
    address public constant COWSWAP_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    IHub public constant HUB_V2 = IHub(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8);
    ILiftERC20 public constant LIFT_ERC20 = ILiftERC20(0x5F99a795dD2743C36D63511f0D4bc667e6d3cDB5);
    INoProtocolFeeLiquidityBootstrappingPoolFactory internal constant LBP_FACTORY =
        INoProtocolFeeLiquidityBootstrappingPoolFactory(0x85a80afee867aDf27B50BdB7b76DA70f1E853062);

    // Token addresses
    address public constant WBTC = 0x8e5bBbb09Ed1ebdE8674Cda39A0c169401db4252;
    address public constant WETH = 0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1;
    address public constant GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address public constant sDAI = 0xaf204776c7245bF4147c2612BF6e5972Ee483701;
    address public constant WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;

    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------
    CirclesBackingFactory public factory;

    // Mock contracts for testing
    MockERC20 public mockToken;
    MockPriceFeed public mockTokenPriceFeed;

    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

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

        // Initialize test accounts with CRC balances
        _setMintTime(TEST_ACCOUNT_1);
        _setMintTime(TEST_ACCOUNT_2);
        _setCRCBalance(
            uint256(uint160(TEST_ACCOUNT_1)), TEST_ACCOUNT_1, HUB_V2.day(block.timestamp), uint192(CRC_AMOUNT * 2)
        );
        _setCRCBalance(
            uint256(uint160(TEST_ACCOUNT_2)), TEST_ACCOUNT_2, HUB_V2.day(block.timestamp), uint192(CRC_AMOUNT * 2)
        );

        // Deploy mock contracts for custom token testing
        mockToken = new MockERC20("MockToken", "MTKN", 18, 1 ether);
        mockTokenPriceFeed = new MockPriceFeed(18, "MockTokenPrice", 1, INITIAL_FEED_PRICE);
    }

    // -------------------------------------------------------------------------
    // Hub-Related Helpers
    // -------------------------------------------------------------------------

    /**
     * @notice Sets Hub mint times for account
     * @param account The account to set mint time for
     */
    function _setMintTime(address account) internal {
        bytes32 accountSlot = keccak256(abi.encodePacked(uint256(uint160(account)), MINT_TIMES_SLOT));
        uint256 mintTime = block.timestamp << 160;
        vm.store(address(HUB_V2), accountSlot, bytes32(mintTime));
    }

    /**
     * @notice Sets Hub ERC1155 balance of id for account
     * @param id The token ID
     * @param account The account to set balance for
     * @param lastUpdatedDay The last updated day
     * @param balance The balance to set
     */
    function _setCRCBalance(uint256 id, address account, uint64 lastUpdatedDay, uint192 balance) internal {
        bytes32 idSlot = keccak256(abi.encodePacked(id, DISCOUNTED_BALANCES_SLOT));
        bytes32 accountSlot = keccak256(abi.encodePacked(uint256(uint160(account)), idSlot));
        uint256 discountedBalance = (uint256(lastUpdatedDay) << 192) + balance;
        vm.store(address(HUB_V2), accountSlot, bytes32(discountedBalance));
    }

    // -------------------------------------------------------------------------
    // Backing Process Helpers
    // -------------------------------------------------------------------------

    /**
     * @notice Initializes a user with backed CRC
     * @param user The user address
     * @param backingAsset The backing asset address
     * @return predictedInstance The predicted CirclesBacking instance address
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

        return predictedInstance;
    }

    /**
     * @notice Simulates a CowSwap fill
     * @param predictedInstance The CirclesBacking instance address
     * @param backingAsset The backing asset address
     * @param fillAmount The fill amount (defaults to BACKING_ASSET_DEAL_AMOUNT)
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
     * @notice Creates an LBP for a CirclesBacking instance
     * @param predictedInstance The CirclesBacking instance address
     */
    function _createLBP(address predictedInstance) internal {
        CirclesBacking(predictedInstance).createLBP();
    }

    /**
     * @notice Sorts tokens by address (ascending order)
     * @param tokenA The first token
     * @param tokenB The second token
     * @return sorted tokens (tokenA, tokenB) in ascending order
     */
    function _sortTokens(IERC20 tokenA, IERC20 tokenB) internal pure returns (IERC20, IERC20) {
        if (address(tokenA) < address(tokenB)) {
            return (tokenA, tokenB);
        }
        return (tokenB, tokenA);
    }
}
