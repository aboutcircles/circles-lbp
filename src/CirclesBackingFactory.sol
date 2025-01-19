// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IGetUid} from "src/interfaces/IGetUid.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {INoProtocolFeeLiquidityBootstrappingPoolFactory} from "src/interfaces/ILBPFactory.sol";
import {ILBP} from "src/interfaces/ILBP.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {ILiftERC20} from "src/interfaces/ILiftERC20.sol";
import {CirclesBacking} from "src/CirclesBacking.sol";

/**
 * @title Circles Backing Factory.
 * @notice Contract allows to create CirclesBacking instances.
 *         Administrates supported backing assets and global balancer pool tokens release.
 */
contract CirclesBackingFactory {
    // Errors
    /// Only HubV2 allowed to call.
    error OnlyHub();
    /// Received CRC amount is `received`, required CRC amount is `required`.
    error NotExactlyRequiredCRCAmount(uint256 required, uint256 received);
    /// Backing is allowed only for Hub human avatars.
    error OnlyHumanAvatarsAreSupported();
    /// Backing in favor is dissalowed. Back only your personal CRC.
    error BackingInFavorDissalowed();
    /// Circles backing does not support `requestedAsset` asset.
    error UnsupportedBackingAsset(address requestedAsset);
    /// Deployment of CirclesBacking instance initiated by user `backer` has failed.
    error CirclesBackingDeploymentFailed(address backer);
    /// Method can be called only by CirclesBacking instance deployed by this factory.
    error OnlyCirclesBacking();
    /// Unauthorized access.
    error NotAdmin();
    /// Exit Liquidity Bootstraping Pool supports only two tokens pools.
    error OnlyTwoTokenLBPSupported();

    // Events
    /// @notice Emitted when a CirclesBacking instance is created.
    event CirclesBackingDeployed(address indexed backer, address indexed circlesBackingInstance);
    /// @notice Emitted when a LBP instance is created.
    event LBPDeployed(address indexed circlesBackingInstance, address indexed lbp);
    /// @notice Emitted when a Circles backing process is initiated.
    event CirclesBackingInitiated(
        address indexed backer,
        address indexed circlesBackingInstance,
        address backingAsset,
        address personalCirclesAddress
    );
    /// @notice Emitted when a Circles backing process is completed.
    event CirclesBackingCompleted(address indexed backer, address indexed circlesBackingInstance, address indexed lbp);
    /// @notice Emitted when a Circles backing is ended by user due to release of LP tokens.
    event Released(address indexed backer, address indexed circlesBackingInstance, address indexed lbp);

    // Constants
    /// @notice Hash of the CirclesBacking instance creation bytecode.
    bytes32 public constant INSTANCE_BYTECODE_HASH = keccak256(type(CirclesBacking).creationCode);
    /// @notice Address allowed to set supported backing assets and global bpt release timestamp.
    address public immutable ADMIN;

    // Cowswap order constants.
    /// @notice Helper contract for crafting Uid.
    IGetUid public constant GET_UID_CONTRACT = IGetUid(address(0xCA51403B524dF7dA6f9D6BFc64895AD833b5d711));
    /// @notice USDC.e contract address.
    address public constant USDC = 0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0;
    /// @notice ERC20 decimals value for USDC.e.
    uint256 internal constant USDC_DECIMALS = 1e6;
    /// @notice Amount of USDC.e to use in a swap for backing asset.
    uint256 public immutable TRADE_AMOUNT;
    /// @notice Deadline for orders expiration - set as timestamp in 5 years after deployment.
    uint32 public immutable VALID_TO;
    /// @notice Order appdata divided into 2 strings to insert deployed instance address.
    string public constant preAppData =
        '{"version":"1.1.0","appCode":"Circles backing powered by AboutCircles","metadata":{"hooks":{"version":"0.1.0","post":[{"target":"';
    string public constant postAppData = '","callData":"0x13e8f89f","gasLimit":"6000000"}]}}}'; // Updated calldata and gaslimit for createLBP

    /// LBP constants.
    /// @notice Balancer v2 Vault.
    address public constant VAULT = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    /// @notice Balancer v2 LBPFactory.
    INoProtocolFeeLiquidityBootstrappingPoolFactory public constant LBP_FACTORY =
        INoProtocolFeeLiquidityBootstrappingPoolFactory(address(0x85a80afee867aDf27B50BdB7b76DA70f1E853062));
    /// @dev LBP token weight 1%.
    uint256 internal constant WEIGHT_1 = 0.01 ether;
    /// @dev LBP token weight 99%.
    uint256 internal constant WEIGHT_99 = 0.99 ether;
    /// @dev Swap fee percentage is set to 1%.
    uint256 internal constant SWAP_FEE = 0.01 ether;
    /// @dev BPT name and symbol prefix.
    string internal constant LBP_PREFIX = "circlesBackingLBP-";

    // Circles constants
    /// @notice Circles Hub v2.
    IHub public constant HUB_V2 = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));
    /// @notice Circles v2 LiftERC20 contract.
    ILiftERC20 public constant LIFT_ERC20 = ILiftERC20(address(0x5F99a795dD2743C36D63511f0D4bc667e6d3cDB5));
    /// @notice Amount of InflationaryCircles to use in LBP initial liquidity.
    uint256 public constant CRC_AMOUNT = 48 ether;

    // Storage
    /// @notice Stores supported assets.
    mapping(address supportedAsset => bool) public supportedBackingAssets;
    /// @notice Links CirclesBacking instances to their creators.
    mapping(address circlesBacking => address backer) public backerOf;
    /// @notice Global release timestamp for balancer pool tokens.
    uint32 public releaseTimestamp = type(uint32).max;

    // Modifiers

    modifier onlyAdmin() {
        if (msg.sender != ADMIN) revert NotAdmin();
        _;
    }

    function onlyCirclesBacking() private view returns (address backer) {
        backer = backerOf[msg.sender];
        if (backer == address(0)) revert OnlyCirclesBacking();
    }

    /**
     * @dev Reentrancy guard for nonReentrant functions.
     * see https://soliditylang.org/blog/2024/01/26/transient-storage/
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

    // Constructor
    constructor(address admin, uint256 usdcInteger) {
        ADMIN = admin;
        TRADE_AMOUNT = usdcInteger * USDC_DECIMALS;
        VALID_TO = uint32(block.timestamp + 1825 days);
        supportedBackingAssets[address(0x8e5bBbb09Ed1ebdE8674Cda39A0c169401db4252)] = true; // WBTC
        supportedBackingAssets[address(0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1)] = true; // WETH
        supportedBackingAssets[address(0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb)] = true; // GNO
        supportedBackingAssets[address(0xaf204776c7245bF4147c2612BF6e5972Ee483701)] = true; // sDAI
    }

    // Admin logic

    /// @notice Method sets global release timestamp for unlocking balancer pool tokens.
    function setReleaseTimestamp(uint32 timestamp) external onlyAdmin {
        releaseTimestamp = timestamp;
    }

    /// @notice Method sets supported status for backing asset.
    function setSupportedBackingAssetStatus(address backingAsset, bool status) external onlyAdmin {
        supportedBackingAssets[backingAsset] = status;
    }

    // Backing logic

    /// @dev Required upfront approval of this contract for `TRADE_AMOUNT` USDC.e.
    /// @dev Is called inside onERC1155Received callback by Hub call Circles ERC1155 transferFrom.
    function startBacking(address backer, address backingAsset, address stableCRCAddress, uint256 stableCRCAmount)
        internal
    {
        if (!supportedBackingAssets[backingAsset]) revert UnsupportedBackingAsset(backingAsset);

        setTransientParameters(backer, backingAsset, stableCRCAddress, stableCRCAmount);

        address instance = deployCirclesBacking(backer);

        setTransientParameters(address(0), address(0), address(0), uint256(0));

        // transfer USDC.e
        IERC20(USDC).transferFrom(backer, instance, TRADE_AMOUNT);
        // transfer stable circles
        IERC20(stableCRCAddress).transfer(instance, stableCRCAmount);

        // create order
        (, bytes32 appData) = getAppData(instance);
        // Generate order UID using the "getUid" contract
        (bytes32 orderDigest,) = GET_UID_CONTRACT.getUid(
            USDC, // sellToken
            backingAsset, // buyToken
            instance, // receiver
            TRADE_AMOUNT, // sellAmount
            1, // buyAmount: Determined by off-chain logic or Cowswap solvers
            VALID_TO, // order expiry
            appData, // appData hash
            0, // FeeAmount
            true, // IsSell
            false // PartiallyFillable
        );
        // Construct the order UID
        bytes memory orderUid = abi.encodePacked(orderDigest, instance, uint32(VALID_TO));
        // Initiate cowswap order
        CirclesBacking(instance).initiateCowswapOrder(orderUid);
        emit CirclesBackingInitiated(backer, instance, backingAsset, stableCRCAddress);
    }

    // LBP logic

    /// @notice Creates LBP with underlying assets: `backingAssetAmount` backingAsset(`backingAsset`) and `CRC_AMOUNT` InflationaryCircles(`personalCRC`).
    /// @dev Only Circles Backing instances are able to call.
    /// @param personalCRC Address of InflationaryCircles (stable ERC20) used as underlying asset in lbp.
    /// @param backingAsset Address of backing asset used as underlying asset in lbp.
    /// @param backingAssetAmount Amount of backing asset used in lbp.
    function createLBP(address personalCRC, uint256 personalCRCAmount, address backingAsset, uint256 backingAssetAmount)
        external
        returns (address lbp, bytes32 poolId, IVault.JoinPoolRequest memory request, address vault)
    {
        address backer = onlyCirclesBacking();
        // prepare inputs
        IERC20[] memory tokens = new IERC20[](2);
        bool tokenZero = personalCRC < backingAsset;
        tokens[0] = tokenZero ? IERC20(personalCRC) : IERC20(backingAsset);
        tokens[1] = tokenZero ? IERC20(backingAsset) : IERC20(personalCRC);

        uint256[] memory weights = new uint256[](2);
        weights[0] = tokenZero ? WEIGHT_1 : WEIGHT_99;
        weights[1] = tokenZero ? WEIGHT_99 : WEIGHT_1;

        // create LBP
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

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = tokenZero ? personalCRCAmount : backingAssetAmount;
        amountsIn[1] = tokenZero ? backingAssetAmount : personalCRCAmount;

        bytes memory userData = abi.encode(ILBP.JoinKind.INIT, amountsIn);

        request = IVault.JoinPoolRequest(tokens, amountsIn, userData, false);
        vault = VAULT;

        emit CirclesBackingCompleted(backer, msg.sender, lbp);
    }

    /// @notice Emits Released event on instance request.
    /// @dev Only Circles Backing instances are able to call.
    function notifyRelease(address lbp) external {
        address backer = onlyCirclesBacking();
        emit Released(backer, msg.sender, lbp);
    }

    /// @notice General wrapper function over vault.exitPool, allows to extract
    ///         liquidity from pool by approving this Factory to spend Balancer Pool Tokens.
    /// @dev Required Balancer Pool Token approval for bptAmount before call
    function exitLBP(address lbp, uint256 bptAmount) external {
        // transfer bpt tokens from msg.sender
        IERC20(lbp).transferFrom(msg.sender, address(this), bptAmount);

        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[0] = uint256(0);
        minAmountsOut[1] = uint256(0);

        bytes32 poolId = ILBP(lbp).getPoolId();

        (IERC20[] memory poolTokens,,) = IVault(VAULT).getPoolTokens(poolId);
        if (poolTokens.length != minAmountsOut.length) revert OnlyTwoTokenLBPSupported();

        // exit pool
        IVault(VAULT).exitPool(
            poolId,
            address(this), // sender
            payable(msg.sender), // recipient
            IVault.ExitPoolRequest(
                poolTokens, minAmountsOut, abi.encode(ILBP.ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT, bptAmount), false
            )
        );
    }

    // View functions

    // counterfactual
    /**
     * @notice Computes the deterministic address for CirclesBacking contract.
     * @param backer Address which is backing circles.
     * @return predictedAddress Predicted address of the deployed contract.
     */
    function computeAddress(address backer) public view returns (address predictedAddress) {
        bytes32 salt = keccak256(abi.encodePacked(backer));
        predictedAddress = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, INSTANCE_BYTECODE_HASH))))
        );
    }

    /// @notice Returns backing parameters.
    function backingParameters()
        external
        view
        returns (
            address transientBacker,
            address transientBackingAsset,
            address transientStableCRC,
            uint256 transientStableCRCAmount,
            address usdc,
            uint256 usdcAmount
        )
    {
        assembly {
            transientBacker := tload(1)
            transientBackingAsset := tload(2)
            transientStableCRC := tload(3)
            transientStableCRCAmount := tload(4)
        }
        usdc = USDC;
        usdcAmount = TRADE_AMOUNT;
    }

    // cowswap app data
    /// @notice Returns stringified json and its hash representing app data for Cowswap.
    function getAppData(address _circlesBackingInstance)
        public
        pure
        returns (string memory appDataString, bytes32 appDataHash)
    {
        string memory instanceAddressStr = addressToString(_circlesBackingInstance);
        appDataString = string.concat(preAppData, instanceAddressStr, postAppData);
        appDataHash = keccak256(bytes(appDataString));
    }

    // personal circles
    /// @notice Returns address of avatar InflationaryCircles.
    /// @dev this call will revert, if avatar is not registered as human or group in Hub contract
    function getPersonalCircles(address avatar) public returns (address inflationaryCircles) {
        inflationaryCircles = LIFT_ERC20.ensureERC20(avatar, uint8(1));
    }

    /// @notice Returns backer's LBP status.
    function isActiveLBP(address backer) external view returns (bool) {
        address instance = computeAddress(backer);
        if (instance.code.length == 0) return false;
        uint256 unlockTimestamp = CirclesBacking(instance).balancerPoolTokensUnlockTimestamp();
        return unlockTimestamp > 0;
    }

    // Internal functions

    // deploy instance
    /**
     * @notice Deploys a new CirclesBacking contract with CREATE2.
     * @param backer Address which is backing circles.
     * @return deployedAddress Address of the deployed contract.
     */
    function deployCirclesBacking(address backer) internal returns (address deployedAddress) {
        bytes32 salt_ = keccak256(abi.encodePacked(backer));

        deployedAddress = address(new CirclesBacking{salt: salt_}());

        if (deployedAddress == address(0) || deployedAddress.code.length == 0) {
            revert CirclesBackingDeploymentFailed(backer);
        }

        // link instance to backer
        backerOf[deployedAddress] = backer;

        emit CirclesBackingDeployed(backer, deployedAddress);
    }

    // transient storage
    /// @dev Sets transient storage values.
    function setTransientParameters(
        address backer,
        address backingAsset,
        address personalStableCRC,
        uint256 stableCRCAmount
    ) internal {
        assembly {
            tstore(1, backer)
            tstore(2, backingAsset)
            tstore(3, personalStableCRC)
            tstore(4, stableCRCAmount)
        }
    }

    // cowswap app data helper
    /// @dev returns string as address value
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

    // personal circles lbp name
    function _name(address inflationaryCirlces) internal view returns (string memory) {
        return string(abi.encodePacked(LBP_PREFIX, IERC20Metadata(inflationaryCirlces).name()));
    }

    // personal circles lbp symbol
    function _symbol(address inflationaryCirlces) internal view returns (string memory) {
        return string(abi.encodePacked(LBP_PREFIX, IERC20Metadata(inflationaryCirlces).symbol()));
    }

    // Callback
    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes calldata data)
        external
        nonReentrant
        returns (bytes4)
    {
        if (msg.sender != address(HUB_V2)) revert OnlyHub();
        if (value != CRC_AMOUNT) revert NotExactlyRequiredCRCAmount(CRC_AMOUNT, value);
        address avatar = address(uint160(id));
        if (!HUB_V2.isHuman(avatar)) revert OnlyHumanAvatarsAreSupported();
        if (operator != from || from != avatar) revert BackingInFavorDissalowed();
        // handling personal CRC
        // get stable address
        address stableCRC = getPersonalCircles(avatar);

        uint256 stableCirclesAmount = IERC20(stableCRC).balanceOf(address(this));
        // wrap erc1155 into stable ERC20
        HUB_V2.wrap(avatar, CRC_AMOUNT, uint8(1));
        stableCirclesAmount = IERC20(stableCRC).balanceOf(address(this)) - stableCirclesAmount;

        // decode backing asset
        address backingAsset = abi.decode(data, (address));

        startBacking(avatar, backingAsset, stableCRC, stableCirclesAmount);
        return this.onERC1155Received.selector;
    }
}
