// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {INoProtocolFeeLiquidityBootstrappingPoolFactory} from "src/interfaces/ILBPFactory.sol";
import {ILBP} from "src/interfaces/ILBP.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {ILiftERC20} from "src/interfaces/ILiftERC20.sol";
import {CirclesBacking} from "src/CirclesBacking.sol";
import {CirclesBackingOrder} from "src/CirclesBackingOrder.sol";
import {ValueFactory} from "src/ValueFactory.sol";
import {GPv2Order} from "composable-cow/BaseConditionalOrder.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";

/**
 * @title Circles Backing Factory
 * @notice This contract creates and manages CirclesBacking instances,
 *         administrates supported backing assets, and coordinates
 *         the Balancer pool token release timeline.
 * @dev The factory:
 *      1. Deploys new CirclesBacking instances via CREATE2.
 *      2. Maintains global parameters like releaseTimestamp.
 *      3. Manages supported backing assets and their oracles/slippage settings.
 *      4. Facilitates starting and completing the Circles backing process.
 */
contract CirclesBackingFactory {
    /*//////////////////////////////////////////////////////////////
                             Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a function is called by any address that is not the HubV2.
    error OnlyHub();

    /// @notice Thrown when the received CRC amount does not match the exact required CRC amount.
    /// @param required The required CRC amount.
    /// @param received The actual CRC amount received.
    error NotExactlyRequiredCRCAmount(uint256 required, uint256 received);

    /// @notice Thrown when the backing process is attempted by a non-human avatar address in the Hub.
    error OnlyHumanAvatarsAreSupported();

    /// @notice Thrown when the Circles backing is attempted on behalf of an address different from the caller (delegated backing is disallowed).
    error BackingInFavorDisallowed();

    /// @notice Thrown when the requested asset is not supported for Circles backing.
    /// @param requestedAsset The address of the unsupported asset.
    error UnsupportedBackingAsset(address requestedAsset);

    /// @notice Thrown when deployment of the CirclesBacking instance fails.
    /// @param backer The address that initiated deployment.
    error CirclesBackingDeploymentFailed(address backer);

    /// @notice Thrown when a function restricted to CirclesBacking instances is called by a non-instance.
    error OnlyCirclesBacking();

    /// @notice Thrown when a function is called by a non-admin address.
    error OnlyAdmin();

    /// @notice Thrown when trying to exit from an Balances pool that does not contain exactly two tokens.
    error OnlyTwoTokenLBPSupported();

    /*//////////////////////////////////////////////////////////////
                             Events
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a CirclesBacking instance is created.
     * @param backer The address which initiated the backing process.
     * @param circlesBackingInstance The address of the newly deployed CirclesBacking instance.
     */
    event CirclesBackingDeployed(address indexed backer, address indexed circlesBackingInstance);

    /**
     * @notice Emitted when an LBP instance is created.
     * @param circlesBackingInstance The associated CirclesBacking instance that invoked LBP creation.
     * @param lbp The newly created LBP address.
     */
    event LBPDeployed(address indexed circlesBackingInstance, address indexed lbp);

    /**
     * @notice Emitted when a Circles backing process is initiated.
     * @param backer The address initiating the backing process.
     * @param circlesBackingInstance The address of the relevant CirclesBacking instance.
     * @param backingAsset The backing asset used.
     * @param personalCirclesAddress The personal (inflationary) Circles ERC20 address being backed.
     */
    event CirclesBackingInitiated(
        address indexed backer,
        address indexed circlesBackingInstance,
        address backingAsset,
        address personalCirclesAddress
    );

    /**
     * @notice Emitted when a Circles backing process is completed.
     * @param backer The address completing the backing process.
     * @param circlesBackingInstance The CirclesBacking instance involved.
     * @param lbp The newly created LBP address.
     */
    event CirclesBackingCompleted(address indexed backer, address indexed circlesBackingInstance, address indexed lbp);

    /**
     * @notice Emitted when a Circles backing is ended by user due to the release of LP tokens.
     * @param backer The address that owned the backing.
     * @param circlesBackingInstance The relevant CirclesBacking instance.
     * @param lbp The address of the LBP from which tokens are released.
     */
    event Released(address indexed backer, address indexed circlesBackingInstance, address indexed lbp);

    /*//////////////////////////////////////////////////////////////
                           Constants
    //////////////////////////////////////////////////////////////*/

    /// @notice Hash of the CirclesBacking instance creation bytecode.
    bytes32 public constant INSTANCE_BYTECODE_HASH = keccak256(type(CirclesBacking).creationCode);

    /// @notice Address allowed to set supported backing assets, global bpt release timestamp, oracles, and slippage in ValueFactory.
    address public immutable ADMIN;

    /// @notice USDC.e contract address on Gnosis Chain.
    address public constant USDC = 0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0;

    /// @notice Unit of USDC.e (6 decimals).
    uint256 internal constant USDC_UNIT = 1e6;

    /// @notice Amount of USDC.e to use in a swap for the backing asset.
    uint256 public immutable TRADE_AMOUNT;

    /// @notice Cowswap Settlement domain separator for Gnosis Chain.
    bytes32 public constant DOMAIN_SEPARATOR =
        bytes32(0x8f05589c4b810bc2f706854508d66d447cd971f8354a4bb0b3471ceb0a466bc7);

    /**
     * @notice Order appdata used by Cowswap for Circles backing.
     *         It's divided into two strings to insert a deployed instance address.
     */
    string public constant preAppData =
        '{"version":"1.1.0","appCode":"Circles backing powered by AboutCircles","metadata":{"hooks":{"version":"0.1.0","post":[{"target":"';
    string public constant postAppData = '","callData":"0x13e8f89f","gasLimit":"6000000"}]}}}';

    /// @notice A specialized conditional order contract used for Circles, integrating Composable CoW.
    CirclesBackingOrder public immutable circlesBackingOrder;

    /// @notice Value factory used to retrieve approximate exchange rates for backing assets.
    ValueFactory public immutable valueFactory;

    /// @notice Balancer v2 Vault address.
    address public constant VAULT = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    /// @notice Balancer v2 LBPFactory address.
    INoProtocolFeeLiquidityBootstrappingPoolFactory public constant LBP_FACTORY =
        INoProtocolFeeLiquidityBootstrappingPoolFactory(address(0x85a80afee867aDf27B50BdB7b76DA70f1E853062));

    /// @dev LBP token weight 10%.
    uint256 internal constant WEIGHT_10 = 0.1 ether;

    /// @dev LBP token weight 90%.
    uint256 internal constant WEIGHT_90 = 0.9 ether;

    /// @dev Swap fee percentage is set to 1% for the LBP.
    uint256 internal constant SWAP_FEE = 0.01 ether;

    /// @dev BPT name and symbol prefix for LBPs created in this factory.
    string internal constant LBP_PREFIX = "circlesBackingLBP-";

    /// @notice Circles Hub v2.
    IHub public constant HUB_V2 = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    /// @notice Circles v2 LiftERC20 contract.
    ILiftERC20 public constant LIFT_ERC20 = ILiftERC20(address(0x5F99a795dD2743C36D63511f0D4bc667e6d3cDB5));

    /// @notice Amount of Circles (ERC1155) to use in LBP initial liquidity.
    uint256 public constant CRC_AMOUNT = 48 ether;

    /*//////////////////////////////////////////////////////////////
                            Storage
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Stores whether an asset is supported for backing.
     * @dev If `true`, the asset is allowed as a valid backing option.
     */
    mapping(address supportedAsset => bool) public supportedBackingAssets;

    /**
     * @notice Mapping from a deployed CirclesBacking instance to the original backer address.
     * @dev This is set upon deployment of a new instance via CREATE2.
     */
    mapping(address circlesBacking => address backer) public backerOf;

    /**
     * @notice Global release timestamp for Balancer pool tokens.
     * @dev CirclesBacking instances use this to restrict or allow BPT withdrawals.
     */
    uint32 public releaseTimestamp = type(uint32).max;

    /*//////////////////////////////////////////////////////////////
                            Modifiers
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Restricts function execution to the designated ADMIN address.
     *      Reverts with `OnlyAdmin` if called by any other address.
     */
    modifier onlyAdmin() {
        if (msg.sender != ADMIN) revert OnlyAdmin();
        _;
    }

    /**
     * @dev Restricts function execution to a valid CirclesBacking instance deployed by this factory.
     *      Reverts with `OnlyCirclesBacking` if caller is not recognized as a CirclesBacking instance.
     * @return backer The original backer who owns the calling CirclesBacking instance.
     */
    function onlyCirclesBacking() private view returns (address backer) {
        backer = backerOf[msg.sender];
        if (backer == address(0)) revert OnlyCirclesBacking();
    }

    /**
     * @dev A minimal non-reentrancy guard using transient storage.
     *      See https://soliditylang.org/blog/2024/01/26/transient-storage/
     */
    modifier nonReentrant() {
        assembly {
            if tload(0) { revert(0, 0) }
            tstore(0, 1)
        }
        _;
        assembly {
            tstore(0, 0)
        }
    }

    /*//////////////////////////////////////////////////////////////
                          Constructor
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the CirclesBackingFactory.
     * @dev Sets default supported backing assets and deploys the specialized CirclesBackingOrder & ValueFactory.
     * @param admin The address that will be assigned as `ADMIN`.
     * @param usdcInteger The integer amount of USDC to be used (1 = 1 USDC, 10 = 10 USDC, etc.).
     *        It is multiplied by 1e6 internally to fit USDC’s 6 decimal places.
     */
    constructor(address admin, uint256 usdcInteger) {
        ADMIN = admin;
        TRADE_AMOUNT = usdcInteger * USDC_UNIT;

        // Set default supported assets: WBTC, WETH, GNO, sDAI on Gnosis Chain.
        supportedBackingAssets[address(0x8e5bBbb09Ed1ebdE8674Cda39A0c169401db4252)] = true; // WBTC
        supportedBackingAssets[address(0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1)] = true; // WETH
        supportedBackingAssets[address(0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb)] = true; // GNO
        supportedBackingAssets[address(0xaf204776c7245bF4147c2612BF6e5972Ee483701)] = true; // sDAI

        circlesBackingOrder = new CirclesBackingOrder(USDC, TRADE_AMOUNT);
        valueFactory = new ValueFactory(USDC, TRADE_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                         Admin-only Logic
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the global release timestamp for unlocking Balancer pool tokens.
     * @dev Only callable by `ADMIN`.
     * @param timestamp The new timestamp (Unix time) after which pool tokens may be unlocked.
     */
    function setReleaseTimestamp(uint32 timestamp) external onlyAdmin {
        releaseTimestamp = timestamp;
    }

    /**
     * @notice Enables or disables a backing asset.
     * @dev Only callable by `ADMIN`.
     * @param backingAsset The address of the asset to set.
     * @param status `true` to support this asset, `false` to disable it.
     */
    function setSupportedBackingAssetStatus(address backingAsset, bool status) external onlyAdmin {
        supportedBackingAssets[backingAsset] = status;
    }

    /**
     * @notice Sets or removes the oracle for a given token in the ValueFactory.
     * @dev Only callable by `ADMIN`. If `priceFeed` is the zero address, the oracle for `token` is removed.
     * @param token The address of the token to configure.
     * @param priceFeed The address of the Chainlink-like oracle feed (or zero to remove).
     */
    function setOracle(address token, address priceFeed) external onlyAdmin {
        valueFactory.setOracle(token, priceFeed);
    }

    /**
     * @notice Updates the slippage basis points in the ValueFactory.
     * @dev Only callable by `ADMIN`. The valid range is typically `[0, MAX_BPS]`.
     * @param newSlippageBPS The new slippage value in basis points.
     */
    function setSlippageBPS(uint256 newSlippageBPS) external onlyAdmin {
        valueFactory.setSlippageBPS(newSlippageBPS);
    }

    /*//////////////////////////////////////////////////////////////
                          Backing Logic
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Starts the Circles backing process by deploying a CirclesBacking instance,
     *      transferring USDC and stableCircles tokens, and initiating a Cowswap order.
     *      Only called internally by `onERC1155Received`.
     * @param backer The address that is backing Circles.
     * @param backingAsset The asset to be used for backing.
     * @param stableCRCAddress The stable Circles ERC20 address for the backer’s personal CRC.
     * @param stableCRCAmount The amount of stable CRC tokens being contributed to the backing process.
     */
    function startBacking(address backer, address backingAsset, address stableCRCAddress, uint256 stableCRCAmount)
        internal
    {
        if (!supportedBackingAssets[backingAsset]) revert UnsupportedBackingAsset(backingAsset);

        // generate the order app data
        (, bytes32 appData) = getAppData(computeAddress(backer));

        // deploy instance
        setTransientParameters(backer, backingAsset, stableCRCAddress, stableCRCAmount, appData);
        address instance = deployCirclesBacking(backer);
        setTransientParameters(address(0), address(0), address(0), uint256(0), bytes32(0));

        // transfer USDC.e from backer to newly deployed CirclesBacking instance
        IERC20(USDC).transferFrom(backer, instance, TRADE_AMOUNT);

        // transfer stable Circles from the factory to the new instance
        IERC20(stableCRCAddress).transfer(instance, stableCRCAmount);

        // Initiate cowswap order
        (uint256 buyAmount, IConditionalOrder.ConditionalOrderParams memory params, bytes memory orderUid) =
        getConditionalParamsAndOrderUid(instance, backingAsset, uint32(block.timestamp + 1 days), appData, uint256(0));

        CirclesBacking(instance).initiateCowswapOrder(buyAmount, params, orderUid);
        emit CirclesBackingInitiated(backer, instance, backingAsset, stableCRCAddress);
    }

    /*//////////////////////////////////////////////////////////////
                          LBP Creation Logic
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates an LBP (Liquidity Bootstrapping Pool) for the CirclesBacking instance.
     * @dev Only callable by a CirclesBacking instance deployed by this factory.
     * @param personalCRC The address of the inflationary Circles ERC20 token.
     * @param personalCRCAmount The amount of personal CRC used for the LBP.
     * @param backingAsset The asset used for backing in the LBP.
     * @param backingAssetAmount The amount of the backing asset used in the LBP.
     * @return lbp The newly created LBP address.
     * @return poolId The ID of the Balancer pool.
     * @return request The constructed JoinPoolRequest.
     * @return vault The Balancer Vault address.
     */
    function createLBP(address personalCRC, uint256 personalCRCAmount, address backingAsset, uint256 backingAssetAmount)
        external
        returns (address lbp, bytes32 poolId, IVault.JoinPoolRequest memory request, address vault)
    {
        address backer = onlyCirclesBacking();

        // Prepare the tokens array for Balancer
        IERC20[] memory tokens = new IERC20[](2);
        bool tokenZero = personalCRC < backingAsset;
        tokens[0] = tokenZero ? IERC20(personalCRC) : IERC20(backingAsset);
        tokens[1] = tokenZero ? IERC20(backingAsset) : IERC20(personalCRC);

        // Set initial weights
        uint256[] memory weights = new uint256[](2);
        weights[0] = tokenZero ? WEIGHT_10 : WEIGHT_90;
        weights[1] = tokenZero ? WEIGHT_90 : WEIGHT_10;

        // Create the LBP
        lbp = LBP_FACTORY.create(
            _name(personalCRC),
            _symbol(personalCRC),
            tokens,
            weights,
            SWAP_FEE,
            msg.sender, // lbp owner
            true // enable swap on start
        );

        emit LBPDeployed(msg.sender, lbp);

        poolId = ILBP(lbp).getPoolId();

        // Prepare amountsIn
        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = tokenZero ? personalCRCAmount : backingAssetAmount;
        amountsIn[1] = tokenZero ? backingAssetAmount : personalCRCAmount;

        // Encode the userData needed for Balancer
        bytes memory userData = abi.encode(ILBP.JoinKind.INIT, amountsIn);
        request = IVault.JoinPoolRequest(tokens, amountsIn, userData, false);
        vault = VAULT;

        emit CirclesBackingCompleted(backer, msg.sender, lbp);
    }

    /**
     * @notice Notifies this factory that a CirclesBacking instance has released its BPT tokens.
     *         Emits a `Released` event.
     * @dev Only callable by a valid CirclesBacking instance.
     * @param lbp The address of the LBP being released.
     */
    function notifyRelease(address lbp) external {
        address backer = onlyCirclesBacking();
        emit Released(backer, msg.sender, lbp);
    }

    /**
     * @notice Exits liquidity from an existing LBP by burning BPT tokens and receiving the underlying assets.
     * @dev Caller must approve this factory to spend their BPT tokens before calling.
     * @param lbp The address of the LBP pool.
     * @param bptAmount The amount of BPT tokens to burn.
     * @param minAmountOut0 The minimum amount of the first underlying asset to receive.
     * @param minAmountOut1 The minimum amount of the second underlying asset to receive.
     */
    function exitLBP(address lbp, uint256 bptAmount, uint256 minAmountOut0, uint256 minAmountOut1) external {
        // Transfer BPT tokens from the caller to this factory
        IERC20(lbp).transferFrom(msg.sender, address(this), bptAmount);

        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[0] = minAmountOut0;
        minAmountsOut[1] = minAmountOut1;

        bytes32 poolId = ILBP(lbp).getPoolId();

        (IERC20[] memory poolTokens,,) = IVault(VAULT).getPoolTokens(poolId);
        if (poolTokens.length != minAmountsOut.length) revert OnlyTwoTokenLBPSupported();

        // Exit the pool via Balancer Vault
        IVault(VAULT).exitPool(
            poolId,
            address(this), // sender
            payable(msg.sender), // recipient
            IVault.ExitPoolRequest(
                poolTokens, minAmountsOut, abi.encode(ILBP.ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT, bptAmount), false
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                        View / Helper Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Computes the deterministic address for a new CirclesBacking instance deployed by this factory.
     * @dev Uses `CREATE2` with a salt derived from the `backer` address and the bytecode hash of CirclesBacking.
     * @param backer The address which intends to deploy the CirclesBacking.
     * @return predictedAddress The predicted address of the CirclesBacking instance.
     */
    function computeAddress(address backer) public view returns (address predictedAddress) {
        bytes32 salt = keccak256(abi.encodePacked(backer));
        predictedAddress = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, INSTANCE_BYTECODE_HASH))))
        );
    }

    /**
     * @notice Returns the current backing parameters stored in transient storage.
     * @return transientBacker The backer’s address.
     * @return transientBackingAsset The address of the backing asset.
     * @return transientStableCRC The address of the personal stable CRC ERC20.
     * @return transientStableCRCAmount The amount of stable CRC used.
     * @return transientAppData The Cowswap appData hash for the backing process.
     * @return usdc The USDC token address (same as `USDC`).
     * @return usdcAmount The fixed `TRADE_AMOUNT` of USDC used in each backing.
     */
    function backingParameters()
        external
        view
        returns (
            address transientBacker,
            address transientBackingAsset,
            address transientStableCRC,
            uint256 transientStableCRCAmount,
            bytes32 transientAppData,
            address usdc,
            uint256 usdcAmount
        )
    {
        assembly {
            transientBacker := tload(1)
            transientBackingAsset := tload(2)
            transientStableCRC := tload(3)
            transientStableCRCAmount := tload(4)
            transientAppData := tload(5)
        }
        usdc = USDC;
        usdcAmount = TRADE_AMOUNT;
    }

    /**
     * @notice Returns the stringified JSON and its keccak256 hash used as `appData` in CowSwap orders.
     * @param _circlesBackingInstance The address of the CirclesBacking instance.
     * @return appDataString The JSON string for `appData`.
     * @return appDataHash The keccak256 hash of `appDataString`.
     */
    function getAppData(address _circlesBackingInstance)
        public
        pure
        returns (string memory appDataString, bytes32 appDataHash)
    {
        string memory instanceAddressStr = addressToString(_circlesBackingInstance);
        appDataString = string.concat(preAppData, instanceAddressStr, postAppData);
        appDataHash = keccak256(bytes(appDataString));
    }

    /**
     * @notice Builds a GPv2Order.Data structure via the CirclesBackingOrder contract.
     * @param owner The address placing the order.
     * @param buyToken The token address to buy (the backing asset).
     * @param buyAmount The amount of `buyToken` to buy.
     * @param validTo The timestamp until which the order is valid.
     * @param appData The CowSwap appData hash.
     * @return order A structured CowSwap GPv2 order data.
     */
    function getOrder(address owner, address buyToken, uint256 buyAmount, uint32 validTo, bytes32 appData)
        public
        view
        returns (GPv2Order.Data memory order)
    {
        order = circlesBackingOrder.getOrder(owner, buyToken, buyAmount, validTo, appData);
    }

    /**
     * @notice Computes the buyAmount, conditional order parameters, and the order UID for a new Circles backing order.
     * @param owner The address for which the order is constructed (circles backing instance).
     * @param backingAsset The asset to buy with USDC.
     * @param orderDeadline The order's validTo time.
     * @param appData The appData hash for CowSwap.
     * @param nonce Arbitrary nonce used for uniqueness in the conditional order salt.
     * @return buyAmount The final computed purchase amount for the backingAsset.
     * @return params The parameters to pass to a conditional order.
     * @return orderUid The unique ID used by CowSwap to identify the order.
     */
    function getConditionalParamsAndOrderUid(
        address owner,
        address backingAsset,
        uint32 orderDeadline,
        bytes32 appData,
        uint256 nonce
    )
        public
        view
        returns (uint256 buyAmount, IConditionalOrder.ConditionalOrderParams memory params, bytes memory orderUid)
    {
        buyAmount = valueFactory.getValue(backingAsset);
        params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(circlesBackingOrder),
            salt: keccak256(abi.encode(owner, nonce)),
            staticInput: abi.encode(backingAsset, buyAmount, orderDeadline, appData) // CirclesBackingOrder.OrderStaticInput
        });

        GPv2Order.Data memory order = getOrder(owner, backingAsset, buyAmount, orderDeadline, appData);
        bytes32 digest = GPv2Order.hash(order, DOMAIN_SEPARATOR);

        orderUid = abi.encodePacked(digest, owner, orderDeadline);
    }

    /**
     * @notice Returns the InflationaryCircles (personal CRC) address for a given avatar.
     * @dev Will revert if the avatar is not recognized as a human or group in the Hub.
     * @param avatar The address representing the user’s identity in the Hub.
     * @return inflationaryCircles The address of the inflationary Circles ERC20 for `avatar`.
     */
    function getPersonalCircles(address avatar) public returns (address inflationaryCircles) {
        inflationaryCircles = LIFT_ERC20.ensureERC20(avatar, uint8(1));
    }

    /**
     * @notice Checks whether the backer has a currently active LBP (unreleased) hold by their CirclesBacking instance.
     * @param backer The address to check for an active LBP.
     * @return Boolean indicating whether an active LBP is found.
     */
    function isActiveLBP(address backer) external view returns (bool) {
        address instance = computeAddress(backer);
        if (instance.code.length == 0) return false;
        uint256 unlockTimestamp = CirclesBacking(instance).balancerPoolTokensUnlockTimestamp();
        return unlockTimestamp > 0;
    }

    /*//////////////////////////////////////////////////////////////
                         Internal Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Deploys a new CirclesBacking contract using `CREATE2`.
     * @param backer The address for which the CirclesBacking instance is deployed.
     * @return deployedAddress The address of the newly deployed CirclesBacking.
     */
    function deployCirclesBacking(address backer) internal returns (address deployedAddress) {
        bytes32 salt_ = keccak256(abi.encodePacked(backer));
        deployedAddress = address(new CirclesBacking{salt: salt_}());

        if (deployedAddress == address(0) || deployedAddress.code.length == 0) {
            revert CirclesBackingDeploymentFailed(backer);
        }

        // Link instance to backer
        backerOf[deployedAddress] = backer;
        emit CirclesBackingDeployed(backer, deployedAddress);
    }

    /**
     * @dev Stores ephemeral parameters in transient storage before deploying the CirclesBacking instance.
     * @param backer The address initiating the backing.
     * @param backingAsset The asset used for backing.
     * @param personalStableCRC The address of the stable Circles ERC20 for the backer.
     * @param stableCRCAmount The amount of stable Circles tokens.
     * @param appData The appData hash used for the CowSwap order.
     */
    function setTransientParameters(
        address backer,
        address backingAsset,
        address personalStableCRC,
        uint256 stableCRCAmount,
        bytes32 appData
    ) internal {
        assembly {
            tstore(1, backer)
            tstore(2, backingAsset)
            tstore(3, personalStableCRC)
            tstore(4, stableCRCAmount)
            tstore(5, appData)
        }
    }

    /**
     * @dev Converts an Ethereum address to its string representation (hexadecimal).
     * @param _addr The address to convert.
     * @return String representation of the address.
     */
    function addressToString(address _addr) internal pure returns (string memory) {
        bytes32 value = bytes32(uint256(uint160(_addr)));
        bytes memory alphabet = "0123456789abcdef";

        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";

        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i + 12] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i + 12] & 0x0f)];
        }

        return string(str);
    }

    /**
     * @dev Constructs the name for a newly created LBP based on the name of the personal CRC.
     * @param inflationaryCirlces The personal CRC token address.
     * @return The constructed LBP name.
     */
    function _name(address inflationaryCirlces) internal view returns (string memory) {
        return string(abi.encodePacked(LBP_PREFIX, IERC20Metadata(inflationaryCirlces).name()));
    }

    /**
     * @dev Constructs the symbol for a newly created LBP based on the symbol of the personal CRC.
     * @param inflationaryCirlces The personal CRC token address.
     * @return The constructed LBP symbol.
     */
    function _symbol(address inflationaryCirlces) internal view returns (string memory) {
        return string(abi.encodePacked(LBP_PREFIX, IERC20Metadata(inflationaryCirlces).symbol()));
    }

    /*//////////////////////////////////////////////////////////////
                           Callback
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice ERC1155 callback invoked when HubV2 transfers CRC tokens to this contract.
     * @dev This function ensures that:
     *      1. The caller is HubV2.
     *      2. The correct CRC amount (48 CRC) is transferred.
     *      3. The avatar is human in HubV2 and not backing on behalf of others.
     *      4. Wraps CRC into stable CRC and initiates the Circles backing process.
     * @param operator The address that initiated the transfer (must be the same as `from`/`avatar`).
     * @param from The address from which CRC tokens are sent (must be the avatar).
     * @param id The CRC token ID, which is the numeric representation of the avatar address.
     * @param value The amount of CRC tokens transferred.
     * @param data Encoded backing asset address.
     * @return The function selector to confirm the ERC1155 receive operation.
     */
    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes calldata data)
        external
        nonReentrant
        returns (bytes4)
    {
        if (msg.sender != address(HUB_V2)) revert OnlyHub();
        if (value != CRC_AMOUNT) revert NotExactlyRequiredCRCAmount(CRC_AMOUNT, value);

        address avatar = address(uint160(id));
        if (!HUB_V2.isHuman(avatar)) revert OnlyHumanAvatarsAreSupported();

        if (operator != from || from != avatar) revert BackingInFavorDisallowed();

        // get stable CRC address for the user
        address stableCRC = getPersonalCircles(avatar);

        uint256 stableCirclesAmount = IERC20(stableCRC).balanceOf(address(this));
        // wrap ERC1155 into stable ERC20
        HUB_V2.wrap(avatar, CRC_AMOUNT, uint8(1));
        stableCirclesAmount = IERC20(stableCRC).balanceOf(address(this)) - stableCirclesAmount;

        // decode the backing asset from `data`
        address backingAsset = abi.decode(data, (address));

        // start the backing process
        startBacking(avatar, backingAsset, stableCRC, stableCirclesAmount);
        return this.onERC1155Received.selector;
    }
}
