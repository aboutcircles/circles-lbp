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
 * @notice Contract allows to create CircleBacking instances.
 *         Factory should have an admin function to make release of lbp for everyone.
 */
contract CirclesBackingFactory {
    /// Circles backing does not support `requestedAsset` asset.
    error UnsupportedBackingAsset(address requestedAsset);
    /// Deployment of CirclesBacking instance initiated by user `backer` has failed.
    error CirclesBackingDeploymentFailed(address backer);
    /// Missing approval of this address to spend personal CRC.
    error PersonalCirclesApprovalIsMissing();
    /// Method can be called only by instance of CirclesBacking deployed by this factory.
    error OnlyCirclesBacking();
    /// Method requires exact `requiredXDai` xDai amount, was provided: `providedXDai`.
    error NotExactXDaiAmount(uint256 providedXDai, uint256 requiredXDai);
    /// LBP was created previously, currently only 1 LBP per user can be created.
    error OnlyOneLBPPerUser();
    /// Exit Liquidity Bootstraping Pool supports only two tokens pools.
    error OnlyTwoTokenLBPSupported();

    /// @notice Emitted when a CirclesBacking is created.
    event CirclesBackingDeployed(address indexed backer, address indexed circlesBackingInstance);
    /// @notice Emitted when a LBP is created.
    event LBPCreated(address indexed circlesBackingInstance, address indexed lbp);

    event CirclesBackingInitiated(
        address indexed backer,
        address indexed circlesBackingInstance,
        address backingAsset,
        address personalCirclesAddress
    );
    event CirclesBackingCompleted(address indexed backer, address indexed circlesBackingInstance, address lbp);

    // Cowswap order constants.
    /// @notice Helper contract for crafting Uid.
    IGetUid public constant GET_UID_CONTRACT = IGetUid(address(0xCA51403B524dF7dA6f9D6BFc64895AD833b5d711));
    /// @notice USDC.e contract address.
    address public constant USDC = 0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0;
    /// @notice ERC20 decimals value for USDC.e.
    uint256 public constant USDC_DECIMALS = 1e6;
    /// @notice Amount of USDC.e to use in a swap for backing asset or for LBP initial liquidity in case USDC.e is backing asset.
    uint256 public constant TRADE_AMOUNT = 100 * USDC_DECIMALS;
    /// @notice Deadline for orders expiration - set as timestamp in 5 years after deployment.
    uint32 public immutable VALID_TO;
    /// @notice Order appdata divided into 2 strings to insert deployed instance address.
    string public constant preAppData =
        '{"version":"1.1.0","appCode":"Circles backing powered by AboutCircles","metadata":{"hooks":{"version":"0.1.0","post":[{"target":"';
    string public constant postAppData = '","callData":"0x13e8f89f","gasLimit":"200000"}]}}}'; // Updated calldata for createLBP

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

    mapping(address supportedAsset => bool) public supportedBackingAssets;
    mapping(address circleBacking => address backer) public backerOf;
    bool public releaseAvailable;

    constructor() {
        VALID_TO = uint32(block.timestamp + 1825 days);
        supportedBackingAssets[address(0x8e5bBbb09Ed1ebdE8674Cda39A0c169401db4252)] = true; // WBTC
        supportedBackingAssets[address(0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1)] = true; // WETH
        supportedBackingAssets[address(0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb)] = true; // GNO
        supportedBackingAssets[address(0xaf204776c7245bF4147c2612BF6e5972Ee483701)] = true; // sDAI
        supportedBackingAssets[USDC] = true; // USDC
    }

    // @dev Required upfront approval of this contract for CRC and USDC.e
    function startBacking(address backingAsset) external {
        if (!supportedBackingAssets[backingAsset]) revert UnsupportedBackingAsset(backingAsset);

        address instance = deployCirclesBacking(msg.sender);

        address personalCirclesAddress = getPersonalCircles(msg.sender);
        // handling personal CRC: 1. try to get Inflationary, if fails 2. try to get 1155 and wrap, if fails revert
        try IERC20(personalCirclesAddress).transferFrom(msg.sender, instance, CRC_AMOUNT) {}
        catch {
            try HUB_V2.safeTransferFrom(msg.sender, address(this), uint256(uint160(msg.sender)), CRC_AMOUNT, "") {
                // NOTE: for now this flow always reverts as not fully implemented
                // Reason why not implemented except lack of time is that we might make startBacking internal function called inside
                // IERC1155Receiver.onERC1155Received and the whole handling personal CRC flow will be refactored.
                // TODO:
                //  0. implement IERC1155Receiver.onERC1155Received here
                //  1. define the exact erc1155 circles amount to get based on constant of erc20 inflationary constant
                //  2. call wrap on HUB_V2 with the exact erc1155 circles amount and type = 1 (infationary)
                //  3. check erc20 inflationary balance of address(this) equal CRC_AMOUNT
                //  4. transfer to instance
            } catch {
                revert PersonalCirclesApprovalIsMissing();
            }
        }

        // handling USDC.e
        IERC20(USDC).transferFrom(msg.sender, instance, TRADE_AMOUNT);

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
        // Initiate backing
        CirclesBacking(instance).initiateBacking(
            msg.sender, backingAsset, personalCirclesAddress, orderUid, USDC, TRADE_AMOUNT
        );
        emit CirclesBackingInitiated(msg.sender, instance, backingAsset, personalCirclesAddress);
    }

    // personal circles

    // @dev this call will revert, if avatar is not registered as human or group in Hub contract
    function getPersonalCircles(address avatar) public view returns (address inflationaryCircles) {
        inflationaryCircles = LIFT_ERC20.erc20Circles(uint8(1), avatar);
        // TODO: find capacity to understand why i had this revert
        //if (inflationaryCircles == address(0)) revert InflationaryCirclesNotExists(avatar);
    }

    // cowswap app data

    function getAppData(address _circlesBackingInstance)
        public
        pure
        returns (string memory appDataString, bytes32 appDataHash)
    {
        string memory instanceAddressStr = addressToString(_circlesBackingInstance);
        appDataString = string.concat(preAppData, instanceAddressStr, postAppData);
        appDataHash = keccak256(bytes(appDataString));
    }

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

    // deploy instance
    /**
     * @notice Deploys a new CirclesBacking contract with CREATE2.
     * @param backer Address which is backing circles.
     * @return deployedAddress Address of the deployed contract.
     */
    function deployCirclesBacking(address backer) internal returns (address deployedAddress) {
        // open question: do we want backer to be able to create only one backing? - this is how it is now.
        // or we allow backer to create multiple backings, 1 per supported backing asset - need to add backing asset to salt.
        bytes32 salt_ = keccak256(abi.encodePacked(backer));

        deployedAddress = address(new CirclesBacking{salt: salt_}());

        if (deployedAddress == address(0) || deployedAddress.code.length == 0) {
            revert CirclesBackingDeploymentFailed(backer);
        }

        // link instance to backer
        backerOf[deployedAddress] = backer;

        emit CirclesBackingDeployed(backer, deployedAddress);
    }

    // counterfactual
    /**
     * @notice Computes the deterministic address for CirclesBacking contract.
     * @param backer Address which is backing circles.
     * @return predictedAddress Predicted address of the deployed contract.
     */
    function computeAddress(address backer) external view returns (address predictedAddress) {
        bytes32 salt = keccak256(abi.encodePacked(backer));
        bytes memory bytecode = type(CirclesBacking).creationCode;
        predictedAddress = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)))))
        );
    }

    // admin logic
    // TODO

    // LBP logic

    /// @notice Creates LBP with underlying assets: `backingAssetAmount` backingAsset(`backingAsset`) and `CRC_AMOUNT` InflationaryCircles(`personalCRC`).
    /// @param personalCRC .
    function createLBP(address personalCRC, address backingAsset, uint256 backingAssetAmount)
        external
        returns (address lbp, bytes32 poolId, IVault.JoinPoolRequest memory request)
    {
        address backer = backerOf[msg.sender];
        if (backer == address(0)) revert OnlyCirclesBacking();

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

        emit LBPCreated(backer, lbp);

        poolId = ILBP(lbp).getPoolId();

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = tokenZero ? CRC_AMOUNT : backingAssetAmount;
        amountsIn[1] = tokenZero ? backingAssetAmount : CRC_AMOUNT;

        bytes memory userData = abi.encode(ILBP.JoinKind.INIT, amountsIn);

        request = IVault.JoinPoolRequest(tokens, amountsIn, userData, false);

        emit CirclesBackingCompleted(backer, msg.sender, lbp);
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

    // Internal functions

    function _name(address inflationaryCirlces) internal view returns (string memory) {
        return string(abi.encodePacked(LBP_PREFIX, IERC20Metadata(inflationaryCirlces).name()));
    }

    function _symbol(address inflationaryCirlces) internal view returns (string memory) {
        return string(abi.encodePacked(LBP_PREFIX, IERC20Metadata(inflationaryCirlces).symbol()));
    }
}
