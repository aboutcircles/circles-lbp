// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {IWXDAI} from "src/interfaces/IWXDAI.sol";
import {ISXDAI} from "src/interfaces/ISXDAI.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {ILiftERC20} from "src/interfaces/ILiftERC20.sol";
import {INoProtocolFeeLiquidityBootstrappingPoolFactory} from "src/interfaces/ILBPFactory.sol";
import {ILBP} from "src/interfaces/ILBP.sol";
import {CirclesBacking} from "src/CirclesBacking.sol";
import {IGetUid} from "src/interfaces/IGetUid.sol";

/**
 * @title Circles Backing Factory.
 * @notice Contract allows to create CircleBacking instances.
 *         Factory should have an admin function to make release of lbp for everyone.
 */
contract CirclesBackingFactory {
    /// Circles backing does not support `requestedAsset` asset.
    error UnsupportedBackingAsset(address requestedAsset);
    /// Method is called by unknown account.
    error NotAUser();
    /// Balancer Pool Tokens are still locked.
    error TokensLockedUntilTimestamp(uint256 timestamp);
    /// Method requires exact `requiredXDai` xDai amount, was provided: `providedXDai`.
    error NotExactXDaiAmount(uint256 providedXDai, uint256 requiredXDai);
    /// LBP was created previously, currently only 1 LBP per user can be created.
    error OnlyOneLBPPerUser();
    /// User `avatar` doesn't have InflationaryCircles.
    error InflationaryCirclesNotExists(address avatar);
    /// Exit Liquidity Bootstraping Pool supports only two tokens pools.
    error OnlyTwoTokenLBPSupported();

    /// @notice Emitted when a LBP is created.
    event LBPCreated(address indexed user, address indexed lbp);

    /// @notice Emitted when a CirclesBacking is created.
    event CirclesBackingDeployed(address indexed deployedAddress, address indexed backer);

    struct LBPData {
        address lbp;
        uint96 bptUnlockTimestamp;
    }

    // order constants
    address public constant GET_UID_CONTRACT = 0xCA51403B524dF7dA6f9D6BFc64895AD833b5d711;
    address public constant USDC = 0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0;
    uint256 public constant USDC_DECIMALS = 1e6;
    uint256 public constant TRADE_AMOUNT = 100 * USDC_DECIMALS;
    uint32 public constant VALID_TO = uint32(1894006860); // timestamp in 5 years

    /// @dev BPT name and symbol prefix.
    string internal constant LBP_PREFIX = "testLBP-";
    /// @notice Amount of xDai to use in LBP initial liquidity.
    uint256 public constant XDAI_AMOUNT = 50 ether;
    /// @notice Amount of InflationaryCircles to use in LBP initial liquidity.
    uint256 public constant CRC_AMOUNT = 48 ether;
    /// @dev LBP token weight 1%.
    uint256 internal constant WEIGHT_1 = 0.01 ether;
    /// @dev LBP token weight 99%.
    uint256 internal constant WEIGHT_99 = 0.99 ether;
    /// @dev LBP token weight 50%.
    uint256 internal constant WEIGHT_50 = 0.5 ether;
    /// @dev Update weight duration.
    //uint256 internal constant UPDATE_WEIGHT_DURATION = 365 days;
    /// @dev Swap fee percentage is set to 1%.
    uint256 internal constant SWAP_FEE = 0.01 ether;

    /// @notice Balancer v2 Vault.
    address public constant VAULT = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    /// @notice Balancer v2 LBPFactory.
    INoProtocolFeeLiquidityBootstrappingPoolFactory public constant LBP_FACTORY =
        INoProtocolFeeLiquidityBootstrappingPoolFactory(address(0x85a80afee867aDf27B50BdB7b76DA70f1E853062));
    /// @notice Circles Hub v2.
    IHub public constant HUB_V2 = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));
    /// @notice Circles v2 LiftERC20 contract.
    ILiftERC20 public constant LIFT_ERC20 = ILiftERC20(address(0x5F99a795dD2743C36D63511f0D4bc667e6d3cDB5));
    /// @notice Wrapped xDAI contract.
    IWXDAI public constant WXDAI = IWXDAI(address(0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d));
    /// @notice Savings xDAI contract.
    ISXDAI public constant SXDAI = ISXDAI(address(0xaf204776c7245bF4147c2612BF6e5972Ee483701));

    mapping(address user => LBPData data) public userToLBPData;

    string public constant preAppData =
        '{"version":"1.1.0","appCode":"Circles backing powered by AboutCircles","metadata":{"hooks":{"version":"0.1.0","post":[{"target":"';
    string public constant postAppData = '","callData":"0xbb5ae136","gasLimit":"200000"}]}}}'; // Updated calldata for checkOrderFilledAndTransfer

    mapping(address supportedAsset => bool) public supportedBackingAssets;

    constructor() {}

    function startBacking(address backingAsset) external {
        if (!supportedBackingAssets[backingAsset]) revert UnsupportedBackingAsset(backingAsset);
        address personalCirclesAddress = getPersonalCircles(msg.sender);
        address instance = deployCirclesBacking(msg.sender);

        // create order
        (, bytes32 appData) = getAppData(instance);
        // Generate order UID using the "getUid" contract
        IGetUid getUidContract = IGetUid(GET_UID_CONTRACT);
        (bytes32 orderDigest,) = getUidContract.getUid(
            USDC,
            backingAsset,
            instance, // Use contract address as the receiver
            TRADE_AMOUNT,
            1, // Determined by off-chain logic or Cowswap solvers
            VALID_TO, // ValidTo timestamp
            appData,
            0, // FeeAmount
            true, // IsSell
            false // PartiallyFillable
        );
        // Construct the order UID
        bytes memory orderUid = abi.encodePacked(orderDigest, instance, uint32(VALID_TO));
        CirclesBacking(instance).initAndCreateOrder(
            msg.sender, backingAsset, personalCirclesAddress, orderUid, USDC, TRADE_AMOUNT
        );
    }

    // personal circles

    function getPersonalCircles(address avatar) public view returns (address inflationaryCircles) {
        inflationaryCircles = LIFT_ERC20.erc20Circles(uint8(1), avatar);
        if (inflationaryCircles == address(0)) revert InflationaryCirclesNotExists(avatar);
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
        bytes32 salt = keccak256(abi.encodePacked(backer));
        bytes memory bytecode = type(CirclesBacking).creationCode;

        assembly {
            deployedAddress := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
            if iszero(extcodesize(deployedAddress)) { revert(0, 0) }
        }

        emit CirclesBackingDeployed(deployedAddress, backer);
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

    // LBP Factory logic

    /// @notice Creates LBP with underlying assets: `XDAI_AMOUNT` SxDAI and `CRC_AMOUNT` InflationaryCircles.
    /// @param updateWeightDuration is temporary replacement of constant ONE_YEAR for testing flexibility.
    /// @dev Required InflationaryCircles approval at least `CRC_AMOUNT` before call
    function createLBP(uint256 updateWeightDuration) external payable {
        // check msg.value
        if (msg.value != XDAI_AMOUNT) revert NotExactXDaiAmount(msg.value, XDAI_AMOUNT);
        // for now only 1 lbp per user
        if (userToLBPData[msg.sender].lbp != address(0)) revert OnlyOneLBPPerUser();

        // check inflationaryCircles
        address inflationaryCirlces = LIFT_ERC20.erc20Circles(uint8(1), msg.sender);
        if (inflationaryCirlces == address(0)) revert InflationaryCirclesNotExists(msg.sender);
        IERC20(inflationaryCirlces).transferFrom(msg.sender, address(this), CRC_AMOUNT);
        // approve vault
        IERC20(inflationaryCirlces).approve(address(VAULT), CRC_AMOUNT);

        // convert xDAI into SxDAI
        WXDAI.deposit{value: msg.value}();
        WXDAI.approve(address(SXDAI), msg.value);
        uint256 shares = SXDAI.deposit(msg.value, address(this));
        // approve vault
        SXDAI.approve(address(VAULT), shares);

        // prepare inputs
        IERC20[] memory tokens = new IERC20[](2);
        bool tokenZero = inflationaryCirlces < address(SXDAI);
        tokens[0] = tokenZero ? IERC20(address(inflationaryCirlces)) : IERC20(address(SXDAI));
        tokens[1] = tokenZero ? IERC20(address(SXDAI)) : IERC20(address(inflationaryCirlces));

        uint256[] memory weights = new uint256[](2);
        weights[0] = tokenZero ? WEIGHT_1 : WEIGHT_99;
        weights[1] = tokenZero ? WEIGHT_99 : WEIGHT_1;

        // create LBP
        address lbp = LBP_FACTORY.create(
            _name(inflationaryCirlces),
            _symbol(inflationaryCirlces),
            tokens,
            weights,
            SWAP_FEE,
            address(this), // lbp owner
            true // enable swap on start
        );
        // attach lbp to user
        userToLBPData[msg.sender].lbp = lbp;

        emit LBPCreated(msg.sender, lbp);

        bytes32 poolId = ILBP(lbp).getPoolId();

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = tokenZero ? CRC_AMOUNT : shares;
        amountsIn[1] = tokenZero ? shares : CRC_AMOUNT;

        bytes memory userData = abi.encode(ILBP.JoinKind.INIT, amountsIn);

        // provide liquidity into lbp
        IVault(VAULT).joinPool(
            poolId,
            address(this), // sender
            address(this), // recipient
            IVault.JoinPoolRequest(tokens, amountsIn, userData, false)
        );

        // update weight gradually
        uint256 timestampInYear = block.timestamp + updateWeightDuration;
        ILBP(lbp).updateWeightsGradually(block.timestamp, timestampInYear, _endWeights());

        // set bpt unlock
        userToLBPData[msg.sender].bptUnlockTimestamp = uint96(timestampInYear);
    }

    function withdrawBalancerPoolTokens() external {
        uint256 unlockTimestamp = userToLBPData[msg.sender].bptUnlockTimestamp;
        if (unlockTimestamp == 0) revert NotAUser();
        if (unlockTimestamp > block.timestamp) revert TokensLockedUntilTimestamp(unlockTimestamp);
        userToLBPData[msg.sender].bptUnlockTimestamp = 0;

        IERC20 lbp = IERC20(userToLBPData[msg.sender].lbp);
        uint256 bptAmount = lbp.balanceOf(address(this));
        lbp.transfer(msg.sender, bptAmount);
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

    function _endWeights() internal pure returns (uint256[] memory endWeights) {
        endWeights = new uint256[](2);
        endWeights[0] = WEIGHT_50;
        endWeights[1] = WEIGHT_50;
    }
}
