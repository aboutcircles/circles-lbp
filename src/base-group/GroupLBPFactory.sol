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

    /// @notice Thrown when an initial weight value is invalid.
    error InvalidInitWeight();

    /// @notice Thrown when a final weight value is invalid.
    error InvalidFinalWeight();

    /// @notice Thrown when an amount parameter is zero or resulting BPT is below minimum.
    error InvalidAmount();

    /// @notice Thrown when the swap fee parameter is out of allowed bounds.
    error InvalidSwapFee();

    /// @notice Thrown when a function is called by an address that is not a deployed Starter instance.
    error OnlyStarter();

    /*//////////////////////////////////////////////////////////////
                             Events
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new LBPStarter is created with its initial configuration.
    /// @param creator The address that created the starter.
    /// @param group The address of the base group for which the starter is created.
    /// @param asset The address of the asset paired with the group in the starter.
    /// @param lbpStarter The address of the newly deployed LBPStarter contract.
    /// @param groupAmount The amount of group tokens to deposit in the starter.
    /// @param assetAmount The amount of asset tokens to deposit in the starter.
    /// @param groupInitWeight The initial weight assigned to the group token.
    /// @param groupFinalWeight The final weight target for the group token.
    /// @param swapFee The swap fee percentage for the pool.
    /// @param updateWeightDuration The duration over which the weights are updated.
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

    /// @notice Emitted when the final LBP pool is successfully created.
    /// @param creator The address that created the starter for the pool creation.
    /// @param group The base group avatar address tied to the pool.
    /// @param lbp The address of the newly created LBP pool.
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

    /// @notice Minimum BPT (Balancer Pool Token) amount required for pool initialization (1e6 units).
    uint256 private constant MIN_BPT = 1e6;

    /// @notice Minimum allowable swap fee - 0.0001%.
    uint256 private constant MIN_SWAP_FEE = 0.000001 ether;

    /// @notice Maximum allowable swap fee - 10%.
    uint256 private constant MAX_SWAP_FEE = 0.1 ether;

    /// @notice Minimum allowable weight for tokens in the pool - 1%.
    uint256 private constant MIN_WEIGHT = 0.01 ether;

    /// @notice Maximum allowable weight for tokens in the pool - 99%.
    uint256 private constant MAX_WEIGHT = 0.99 ether;

    // Defaults

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

    /// @notice Mapping of LBPStarter address to creator.
    mapping(address starter => address creator) public starterCreator;

    /// @notice Mapping of LBP pool address to starter creator.
    mapping(address lbp => address creator) public lbpCreator;

    /*//////////////////////////////////////////////////////////////
                            Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @dev Ensures caller is a deployed LBPStarter instance; returns its creator address.
    /// @return creator The address that created the calling starter.
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

    /// @notice Deploys a new LBPStarter contract with custom parameters.
    /// @param group The base group avatar address to use in the LBP.
    /// @param asset The ERC20 asset address to pool against the group token.
    /// @param groupAmount Amount of group tokens to deposit in the starter.
    /// @param assetAmount Amount of asset tokens to deposit in the starter.
    /// @param groupInitWeight Initial weight of group token in the pool (1e18 precision).
    /// @param groupFinalWeight Final weight target of group token after ramp (1e18 precision).
    /// @param swapFee Swap fee for trades, in Balancer's 1e18 representation.
    /// @param updateWeightDuration Duration over which weights linearly update.
    /// @return lbpStarter The address of the newly deployed starter contract.
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

        // link starter to creator
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

    /// @notice Deploys a new LBPStarter contract using default weights, update duration and fee.
    /// @param group The base group avatar address to use in the LBP.
    /// @param asset The ERC20 asset address to pool against the group token.
    /// @param groupAmount Amount of group tokens to deposit in the starter.
    /// @param assetAmount Amount of asset tokens to deposit in the starter.
    /// @return lbpStarter The address of the newly deployed starter contract.
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

    /// @notice Creates the final Balancer LBP pool and constructs the join request.
    /// @dev Only callable by a valid starter instance deployed by this factory.
    /// @param asset The ERC20 asset address used in the pool.
    /// @param stableCRC The CRC token address used in the pool.
    /// @param stableCRCAmount Initial amount of CRC tokens to deposit.
    /// @param assetAmount Initial amount of asset tokens to deposit.
    /// @param weightCRC Initial weight assigned to the CRC token (1e18 precision).
    /// @param swapFee Swap fee for the pool (1e18 precision).
    /// @param group The base group address for reference in event.
    /// @return lbp The address of the created Balancer LBP pool.
    /// @return request The IVault.JoinPoolRequest struct to join the pool.
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

        bytes memory userData = abi.encode(ILBP.JoinKind.INIT, amountsIn);
        request = IVault.JoinPoolRequest(tokens, amountsIn, userData, false);

        // link pool to creator
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

    /// @notice Returns the inflationary token amount equivalent to a demurrage token amount.
    /// @param demmurageAmount The amount in demurrage (non-inflationary) units.
    /// @return stableAmount The converted inflationary token amount.
    function getStableAmount(uint256 demmurageAmount) public view returns (uint256 stableAmount) {
        uint64 day = HUB_V2.day(block.timestamp);
        stableAmount = HUB_V2.convertDemurrageToInflationaryValue(demmurageAmount, day);
    }

    /*//////////////////////////////////////////////////////////////
                        Internal Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Validates nonzero amounts and minimum BPT invariant requirement.
    /// @param crcZero Boolean indicating if CRC token is sorted first.
    /// @param groupInitWeight Initial weight of the group token.
    /// @param groupAmount Amount of group tokens to deposit.
    /// @param assetAmount Amount of asset tokens to deposit.
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

    /// @dev Constructs the pool name by prefixing the group name.
    /// @param inflationaryCircles Address of the CRC ERC20 token.
    /// @return The generated pool name string.
    function _name(address inflationaryCircles) internal view returns (string memory) {
        return string(abi.encodePacked(LBP_PREFIX, _groupName(inflationaryCircles)));
    }

    /// @dev Constructs the pool symbol by prefixing the CRC token symbol.
    /// @param inflationaryCircles Address of the CRC ERC20 token.
    /// @return The generated pool symbol string.
    function _symbol(address inflationaryCircles) internal view returns (string memory) {
        return string(abi.encodePacked(LBP_PREFIX, IERC20Metadata(inflationaryCircles).symbol()));
    }

    /// @dev Retrieves the group name from the CRC token and strips the trailing suffix.
    /// @param inflationaryCircles Address of the CRC ERC20 token.
    /// @return groupName The trimmed group name.
    function _groupName(address inflationaryCircles) internal view returns (string memory groupName) {
        groupName = IERC20Metadata(inflationaryCircles).name();
        assembly {
            let len := mload(groupName)
            let newLen := sub(len, 7)
            mstore(groupName, newLen)
        }
    }

    /// @dev Returns the initial weights for two tokens based on ordering.
    /// @param crcZero True if CRC token sorts first in tokens array.
    /// @param weightCRC The initial weight for the CRC token.
    /// @return weights A two-element array of weights for [first, second] tokens.
    function _initWeights(bool crcZero, uint256 weightCRC) internal pure returns (uint256[] memory weights) {
        weights = new uint256[](2);
        weights[0] = crcZero ? weightCRC : 1 ether - weightCRC;
        weights[1] = crcZero ? 1 ether - weightCRC : weightCRC;
    }
}
