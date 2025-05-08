// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {IBaseGroupFactory} from "src/interfaces/base-group/IBaseGroupFactory.sol";
import {IBaseGroup} from "src/interfaces/base-group/IBaseGroup.sol";
import {IBaseMintHandler} from "src/interfaces/base-group/IBaseMintHandler.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {INoProtocolFeeLiquidityBootstrappingPoolFactory} from "src/interfaces/ILBPFactory.sol";
import {ILBP} from "src/interfaces/ILBP.sol";
import {IExternalWeightedMath} from "src/interfaces/base-group/IExternalWeightedMath.sol";
import {LBPStarter} from "src/base-group/LBPStarter.sol";

/// @title Group LBP Factory
/// @notice Factory contract to deploy Balancer Liquidity Bootstrapping Pools (LBPs) Starters for Circles Group CRC tokens.
contract GroupLBPFactory {
    /*//////////////////////////////////////////////////////////////
                             Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the provided group address is not a Base Group.
    error OnlyBaseGroupsAreSupported();

    /// @notice Thrown when trying to exit a pool that does not contain exactly two tokens.
    error OnlyTwoTokenLBPSupported();

    error InvalidInitWeight();

    error InvalidFinalWeight();

    error InvalidAmount();

    error InvalidSwapFee();

    error OnlyStarter();

    /*//////////////////////////////////////////////////////////////
                             Events
    //////////////////////////////////////////////////////////////*/

    event LBPStarterCreated(
        address indexed creator,
        address indexed group,
        address indexed asset,
        address lbpStarter,
        uint256 groupAmount,
        uint256 assetAmount,
        uint256 groupInitWeight,
        uint256 groupFinalWeight,
        uint256 swapFee,
        uint256 updateWeightDuration
    );

    /// @notice Emitted when a group LBP creation process is completed.
    /// @param creator The address that created the LBP and provided initial liquidity.
    /// @param group The base group avatar address for which the LBP was created.
    /// @param lbp The address of the newly deployed LBP pool.
    event GroupLBPCreated(address indexed creator, address indexed group, address indexed lbp);

    /*//////////////////////////////////////////////////////////////
                           Constants
    //////////////////////////////////////////////////////////////*/

    /// @notice Circles Hub v2 contract address.
    IHub public constant HUB_V2 = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    /// @notice BaseGroupFactory contract address.
    IBaseGroupFactory public constant BASE_GROUP_FACTORY =
        IBaseGroupFactory(address(0xD0B5Bd9962197BEaC4cbA24244ec3587f19Bd06d));

    /// @notice Balancer V2 Vault contract address.
    address public constant VAULT = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    /// @notice Balancer V2 External Weighted Math contract address.
    IExternalWeightedMath public constant BALANCER_WEIGHTED_MATH =
        IExternalWeightedMath(0x9129E834e15eA19b6069e8f08a8EcFc13686B8dC);

    /// @notice Balancer V2 NoProtocolFee Liquidity Bootstrapping Pool Factory address.
    INoProtocolFeeLiquidityBootstrappingPoolFactory public constant LBP_FACTORY =
        INoProtocolFeeLiquidityBootstrappingPoolFactory(address(0x85a80afee867aDf27B50BdB7b76DA70f1E853062));

    /// @dev Prefix for naming Balancer Pool Tokens (BPT) created by this factory.
    string internal constant LBP_PREFIX = "groupLBP-";

    // Requirements
    uint256 private constant MIN_BPT = 1e6;
    uint256 private constant MIN_SWAP_FEE = 0.000001 ether; // 0.0001%
    uint256 private constant MAX_SWAP_FEE = 0.1 ether; // 10%
    uint256 private constant MIN_WEIGHT = 0.01 ether; // 1%
    uint256 private constant MAX_WEIGHT = 0.99 ether; // 99%

    // DEFAULTS
    /// @dev Weight for CRC token at pool initialization (1%).
    uint256 internal constant INIT_WEIGHT = 0.01 ether;

    /// @notice Final target weight for each token after weight ramp (50% each).
    uint256 internal constant FINAL_WEIGHT = 0.5 ether;

    /// @dev Swap fee percentage for the LBP (1%).
    uint256 internal constant SWAP_FEE = 0.01 ether;

    /// @notice Duration over which pool weights are gradually updated (60 days).
    uint256 internal constant UPDATE_WEIGHT_DURATION = 60 days;

    /*//////////////////////////////////////////////////////////////
                            Storage
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping of LBPStarter address to group it created for.
    mapping(address starter => address creator) public starterCreator;

    /// @notice Mapping of LBP pool address to its creator.
    mapping(address lbp => address creator) public lbpCreator;

    /*//////////////////////////////////////////////////////////////
                            Modifiers
    //////////////////////////////////////////////////////////////*/
    /**
     * @dev Restricts function execution to a valid LBPStarter instance deployed by this factory.
     *      Reverts with `OnlyLBPStarter` if caller is not recognized as a LBPStarter instance.
     */
    function onlyStarter() private view returns (address creator) {
        creator = starterCreator[msg.sender];
        if (creator == address(0)) revert OnlyStarter();
    }

    /*//////////////////////////////////////////////////////////////
                          Constructor
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the GroupLBPFactory.
    constructor() {}

    /*//////////////////////////////////////////////////////////////
                          LBPStarter Creation Logic
    //////////////////////////////////////////////////////////////*/

    // fully parametrized config
    function createLBPStarter(
        address group,
        address asset,
        uint256 groupAmount,
        uint256 assetAmount,
        uint256 groupInitWeight,
        uint256 groupFinalWeight,
        uint256 swapFee,
        uint256 updateWeightDuration
    ) public returns (address lbpStarter) {
        if (!BASE_GROUP_FACTORY.deployedByFactory(group)) revert OnlyBaseGroupsAreSupported();
        address stableERC20CRC = IBaseMintHandler(IBaseGroup(group).BASE_MINT_HANDLER()).INFLATIONARY();
        _validateAmounts(stableERC20CRC < asset, groupInitWeight, groupAmount, assetAmount);

        if (groupInitWeight < MIN_WEIGHT || groupInitWeight > MAX_WEIGHT) revert InvalidInitWeight();
        if (groupFinalWeight < MIN_WEIGHT || groupFinalWeight > MAX_WEIGHT) revert InvalidFinalWeight();
        if (swapFee < MIN_SWAP_FEE || swapFee > MAX_SWAP_FEE) revert InvalidSwapFee();

        lbpStarter = address(
            new LBPStarter(
                msg.sender,
                group,
                asset,
                groupAmount,
                assetAmount,
                groupInitWeight,
                groupFinalWeight,
                swapFee,
                updateWeightDuration,
                stableERC20CRC,
                _groupName(stableERC20CRC)
            )
        );

        // link
        starterCreator[lbpStarter] = msg.sender;

        emit LBPStarterCreated(
            msg.sender,
            group,
            asset,
            lbpStarter,
            groupAmount,
            assetAmount,
            groupInitWeight,
            groupFinalWeight,
            swapFee,
            updateWeightDuration
        );
    }

    // default config with assets and amounts parametrized
    function createLBPStarter(address group, address asset, uint256 groupAmount, uint256 assetAmount)
        external
        returns (address lbpStarter)
    {
        lbpStarter = createLBPStarter(
            group, asset, groupAmount, assetAmount, INIT_WEIGHT, FINAL_WEIGHT, SWAP_FEE, UPDATE_WEIGHT_DURATION
        );
    }

    /*//////////////////////////////////////////////////////////////
                        LBP Creation/Exit Helpers
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates an LBP (Liquidity Bootstrapping Pool) for the LBPStarter instance.
     * @dev Only callable by a LBPStarter instance deployed by this factory.
     * @return lbp The newly created LBP address.
     * @return request The constructed JoinPoolRequest.
     */
    function createLBP(
        address asset,
        address stableCRC,
        uint256 stableCRCAmount,
        uint256 assetAmount,
        uint256 weightCRC,
        uint256 swapFee,
        address group
    ) external returns (address lbp, IVault.JoinPoolRequest memory request) {
        address creator = onlyStarter();

        bool crcZero = stableCRC < asset;
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = crcZero ? IERC20(stableCRC) : IERC20(asset);
        tokens[1] = crcZero ? IERC20(asset) : IERC20(stableCRC);

        // Create the LBP
        lbp = LBP_FACTORY.create(
            _name(stableCRC),
            _symbol(stableCRC),
            tokens,
            _initWeights(crcZero, weightCRC),
            swapFee,
            msg.sender, // lbp owner
            true // enable swap on start
        );

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = crcZero ? stableCRCAmount : assetAmount;
        amountsIn[1] = crcZero ? assetAmount : stableCRCAmount;

        // Encode the userData needed for Balancer
        bytes memory userData = abi.encode(ILBP.JoinKind.INIT, amountsIn);
        request = IVault.JoinPoolRequest(tokens, amountsIn, userData, false);

        // link
        lbpCreator[lbp] = creator;

        emit GroupLBPCreated(creator, group, lbp);
    }

    /// @notice Exits liquidity from an existing LBP by burning BPT tokens.
    /// @dev Caller must have approved this factory to spend their BPT tokens.
    /// @param lbp The address of the LBP pool.
    /// @param bptAmount The amount of BPT tokens to burn.
    /// @param minAmountOut0 The minimum amount of the first underlying token to receive.
    /// @param minAmountOut1 The minimum amount of the second underlying token to receive.
    function exitLBP(address lbp, uint256 bptAmount, uint256 minAmountOut0, uint256 minAmountOut1) external {
        IERC20(lbp).transferFrom(msg.sender, address(this), bptAmount);

        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[0] = minAmountOut0;
        minAmountsOut[1] = minAmountOut1;

        bytes32 poolId = ILBP(lbp).getPoolId();

        (IERC20[] memory poolTokens,,) = IVault(VAULT).getPoolTokens(poolId);
        if (poolTokens.length != minAmountsOut.length) revert OnlyTwoTokenLBPSupported();

        IVault(VAULT).exitPool(
            poolId,
            address(this), // sender
            payable(msg.sender), // recipient
            IVault.ExitPoolRequest({
                assets: poolTokens,
                minAmountsOut: minAmountsOut,
                userData: abi.encode(ILBP.ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT, bptAmount),
                toInternalBalance: false
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                        View Functions
    //////////////////////////////////////////////////////////////*/

    function getStableAmount(uint256 demmurageAmount) public view returns (uint256 stableAmount) {
        uint64 day = HUB_V2.day(block.timestamp);
        stableAmount = HUB_V2.convertDemurrageToInflationaryValue(demmurageAmount, day);
    }

    /*//////////////////////////////////////////////////////////////
                        Internal Functions
    //////////////////////////////////////////////////////////////*/

    function _validateAmounts(bool crcZero, uint256 groupInitWeight, uint256 groupAmount, uint256 assetAmount)
        internal
        view
    {
        if (groupAmount == 0 || assetAmount == 0) revert InvalidAmount();
        uint256[] memory normalizedWeights = new uint256[](2);
        normalizedWeights[0] = crcZero ? groupInitWeight : 1 ether - groupInitWeight;
        normalizedWeights[1] = crcZero ? 1 ether - groupInitWeight : groupInitWeight;

        uint256 stableCRCAmount = getStableAmount(groupAmount);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = crcZero ? stableCRCAmount : assetAmount;
        amounts[1] = crcZero ? assetAmount : stableCRCAmount;

        uint256 bptAmount = BALANCER_WEIGHTED_MATH.calculateInvariant(normalizedWeights, amounts) * 2;
        if (bptAmount < MIN_BPT) revert InvalidAmount();
    }

    /// @dev Constructs the name for a newly created LBP by prefixing the group CRC name.
    /// @param inflationaryCircles The address of the CRC ERC20 token.
    /// @return The constructed LBP pool name.
    function _name(address inflationaryCircles) internal view returns (string memory) {
        return string(abi.encodePacked(LBP_PREFIX, _groupName(inflationaryCircles)));
    }

    /// @dev Constructs the symbol for a newly created LBP by prefixing the CRC token symbol.
    /// @param inflationaryCircles The address of the CRC ERC20 token.
    /// @return The constructed LBP pool symbol.
    function _symbol(address inflationaryCircles) internal view returns (string memory) {
        return string(abi.encodePacked(LBP_PREFIX, IERC20Metadata(inflationaryCircles).symbol()));
    }

    function _groupName(address inflationaryCircles) internal view returns (string memory groupName) {
        groupName = IERC20Metadata(inflationaryCircles).name();
        assembly {
            let len := mload(groupName)
            let newLen := sub(len, 7)
            mstore(groupName, newLen)
        }
    }

    /// @dev Returns initial weights array for pool creation based on token ordering.
    /// @param crcZero True if CRC token is sorted first, false if asset is first.
    /// @param weightCRC Initial CRC weight in a pool.
    /// @return weights Two-element array of initial weights.
    function _initWeights(bool crcZero, uint256 weightCRC) internal pure returns (uint256[] memory weights) {
        weights = new uint256[](2);
        weights[0] = crcZero ? weightCRC : 1 ether - weightCRC;
        weights[1] = crcZero ? 1 ether - weightCRC : weightCRC;
    }
}
