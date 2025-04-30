// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {INoProtocolFeeLiquidityBootstrappingPoolFactory} from "src/interfaces/ILBPFactory.sol";
import {ILBP} from "src/interfaces/ILBP.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {IBaseGroupFactory} from "src/interfaces/base-group/IBaseGroupFactory.sol";
import {IBaseGroup} from "src/interfaces/base-group/IBaseGroup.sol";
import {IBaseMintHandler} from "src/interfaces/base-group/IBaseMintHandler.sol";
import {ISDAI} from "src/interfaces/ISDAI.sol";

/// @title Group LBP Factory
/// @notice Factory contract to deploy Balancer Liquidity Bootstrapping Pools (LBPs) for Circles Group CRC tokens paired against sDAI.
/// @dev Interacts with Circles Hub v2 for wrapping CRC tokens, and with Balancer V2 for pool creation and liquidity provision.
contract GroupLBPFactory {
    /*//////////////////////////////////////////////////////////////
                             Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a function is called by any address that is not the Circles Hub v2.
    error OnlyHub();

    /// @notice Thrown when the received CRC amount does not match the exact required CRC amount.
    /// @param required The required CRC token amount.
    /// @param received The actual CRC token amount received.
    error NotExactlyRequiredCRCAmount(uint256 required, uint256 received);

    /// @notice Thrown when the provided avatar address is not a Base Group.
    error OnlyBaseGroupsAreSupported();

    /// @notice Thrown when attempting to create more than one LBP for the same creator and group.
    error OnlyOneLBPPerGroup();

    /// @notice Thrown when trying to exit a pool that does not contain exactly two tokens.
    error OnlyTwoTokenLBPSupported();

    /*//////////////////////////////////////////////////////////////
                             Events
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a group LBP creation process is completed.
    /// @param creator The address that created the LBP and provided initial liquidity.
    /// @param group The base group avatar address for which the LBP was created.
    /// @param lbp The address of the newly deployed LBP pool.
    event GroupLBPCreated(address indexed creator, address indexed group, address indexed lbp);

    /*//////////////////////////////////////////////////////////////
                           Constants
    //////////////////////////////////////////////////////////////*/

    /// @notice Circles Hub v2 contract address.
    address public constant HUB_V2 = address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8);

    /// @notice BaseGroupFactory contract address.
    IBaseGroupFactory public constant BASE_GROUP_FACTORY =
        IBaseGroupFactory(address(0xD0B5Bd9962197BEaC4cbA24244ec3587f19Bd06d));

    /// @notice Balancer V2 NoProtocolFee Liquidity Bootstrapping Pool Factory address.
    INoProtocolFeeLiquidityBootstrappingPoolFactory public constant LBP_FACTORY =
        INoProtocolFeeLiquidityBootstrappingPoolFactory(address(0x85a80afee867aDf27B50BdB7b76DA70f1E853062));

    /// @notice Balancer V2 Vault contract address.
    address public constant VAULT = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    /// @notice sDAI token contract address on Gnosis Chain.
    address public constant SDAI = 0xaf204776c7245bF4147c2612BF6e5972Ee483701;

    /// @notice Amount of xDAI to use when calculating sDAI shares for initial liquidity (1,000 xDAI).
    uint256 public constant STABLE_AMOUNT = 1_000 ether;

    /// @notice Amount of group CRC tokens (ERC1155) for initial LBP liquidity (480 CRC).
    uint256 public constant CRC_AMOUNT = 480 ether;

    /// @dev Weight for CRC token at pool initialization (1%).
    uint256 internal constant WEIGHT_CRC = 0.01 ether;

    /// @dev Weight for sDAI token at pool initialization (99%).
    uint256 internal constant WEIGHT_SDAI = 0.99 ether;

    /// @notice Final target weight for each token after weight ramp (50% each).
    uint256 internal constant WEIGHT_FINAL = 0.5 ether;

    /// @notice Duration over which pool weights are gradually updated (60 days).
    uint256 internal constant UPDATE_WEIGHT_DURATION = 60 days;

    /// @dev Swap fee percentage for the LBP (1%).
    uint256 internal constant SWAP_FEE = 0.01 ether;

    /// @dev Prefix for naming Balancer Pool Tokens (BPT) created by this factory.
    string internal constant LBP_PREFIX = "groupLBP-";

    /*//////////////////////////////////////////////////////////////
                            Storage
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping of creator address and group avatar to deployed LBP pool address.
    mapping(address creator => mapping(address group => address lbp)) public lbpOf;

    /// @notice Mapping of LBP pool address to its creator.
    mapping(address lbp => address creator) public lbpCreator;

    /// @notice Mapping of LBP pool address to its group avatar.
    mapping(address lbp => address group) public lbpGroup;

    /*//////////////////////////////////////////////////////////////
                            Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @dev Non-reentrant guard using transient storage pattern.
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

    /// @notice Initializes the GroupLBPFactory.
    constructor() {}

    /*//////////////////////////////////////////////////////////////
                          LBP Creation Logic
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a new Balancer LBP for the specified group, pairing its CRC token with sDAI.
    /// @dev Requires sDAI preapproval.
    /// @param creator The address providing initial liquidity and receiving BPT tokens.
    /// @param group The group avatar address for which to create the LBP.
    /// @param stableCRCAddress The ERC20 address of the wrapped CRC token.
    /// @param stableCRCAmount The amount of wrapped CRC tokens to deposit as initial liquidity.
    function createGroupLBP(address creator, address group, address stableCRCAddress, uint256 stableCRCAmount)
        internal
    {
        if (lbpOf[creator][group] != address(0)) revert OnlyOneLBPPerGroup();

        // Convert xDAI amount to sDAI shares and transfer from creator
        uint256 sDAIEquivalent = ISDAI(SDAI).convertToShares(STABLE_AMOUNT);
        IERC20(SDAI).transferFrom(creator, address(this), sDAIEquivalent);

        // Arrange token order based on address sorting
        IERC20[] memory tokens = new IERC20[](2);
        bool tokenZero = stableCRCAddress < SDAI;
        tokens[0] = tokenZero ? IERC20(stableCRCAddress) : IERC20(SDAI);
        tokens[1] = tokenZero ? IERC20(SDAI) : IERC20(stableCRCAddress);

        // Deploy the LBP via Balancer factory
        address lbp = LBP_FACTORY.create(
            _name(stableCRCAddress),
            _symbol(stableCRCAddress),
            tokens,
            _initWeights(tokenZero),
            SWAP_FEE,
            address(this), // lbp owner
            true // enable swap on start
        );

        bytes32 poolId = ILBP(lbp).getPoolId();

        // Prepare join parameters
        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = tokenZero ? stableCRCAmount : sDAIEquivalent;
        amountsIn[1] = tokenZero ? sDAIEquivalent : stableCRCAmount;

        bytes memory userData = abi.encode(ILBP.JoinKind.INIT, amountsIn);
        IVault.JoinPoolRequest memory request = IVault.JoinPoolRequest({
            assets: tokens,
            maxAmountsIn: amountsIn,
            userData: userData,
            fromInternalBalance: false
        });

        // Approve Vault to pull tokens
        IERC20(stableCRCAddress).approve(VAULT, stableCRCAmount);
        IERC20(SDAI).approve(VAULT, sDAIEquivalent);
        // Provide initial liquidity into the LBP and set the creator as BPT recipient
        IVault(VAULT).joinPool(poolId, address(this), creator, request);

        // Schedule weight ramp to equal 50/50 over duration
        ILBP(lbp).updateWeightsGradually(block.timestamp, block.timestamp + UPDATE_WEIGHT_DURATION, _endWeights());

        // Store linking and emit event
        lbpOf[creator][group] = lbp;
        lbpCreator[lbp] = creator;
        lbpGroup[lbp] = group;

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
                        Internal Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Constructs the name for a newly created LBP by prefixing the CRC token name.
    /// @param inflationaryCircles The address of the CRC ERC20 token.
    /// @return The constructed LBP pool name.
    function _name(address inflationaryCircles) internal view returns (string memory) {
        return string(abi.encodePacked(LBP_PREFIX, IERC20Metadata(inflationaryCircles).name()));
    }

    /// @dev Constructs the symbol for a newly created LBP by prefixing the CRC token symbol.
    /// @param inflationaryCircles The address of the CRC ERC20 token.
    /// @return The constructed LBP pool symbol.
    function _symbol(address inflationaryCircles) internal view returns (string memory) {
        return string(abi.encodePacked(LBP_PREFIX, IERC20Metadata(inflationaryCircles).symbol()));
    }

    /// @dev Returns initial weights array for pool creation based on token ordering.
    /// @param tokenZero True if CRC token is sorted first, false if sDAI is first.
    /// @return initWeights Two-element array of initial weights.
    function _initWeights(bool tokenZero) internal pure returns (uint256[] memory initWeights) {
        initWeights = new uint256[](2);
        initWeights[0] = tokenZero ? WEIGHT_CRC : WEIGHT_SDAI;
        initWeights[1] = tokenZero ? WEIGHT_SDAI : WEIGHT_CRC;
    }

    /// @notice Returns the end weights array for the LBP (50% each).
    /// @return endWeights Two-element array of final weights.
    function _endWeights() internal pure returns (uint256[] memory endWeights) {
        endWeights = new uint256[](2);
        endWeights[0] = WEIGHT_FINAL;
        endWeights[1] = WEIGHT_FINAL;
    }

    /*//////////////////////////////////////////////////////////////
                           Callback
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC1155 callback invoked when the Circles Hub v2 transfers CRC tokens to this contract.
    /// @dev Validates caller, CRC amount, wraps ERC1155 CRC into ERC20, and triggers LBP creation.
    /// @param from The address from which CRC tokens are sent.
    /// @param id The CRC token ID, representing the numeric avatar address.
    /// @param value The amount of CRC tokens transferred.
    /// @param data Encoded (tbd).
    /// @return The ERC1155Receiver selector to confirm receipt.
    function onERC1155Received(address, address from, uint256 id, uint256 value, bytes calldata data)
        external
        nonReentrant
        returns (bytes4)
    {
        if (msg.sender != HUB_V2) revert OnlyHub();
        if (value != CRC_AMOUNT) revert NotExactlyRequiredCRCAmount(CRC_AMOUNT, value);

        address groupAvatar = address(uint160(id));
        if (!BASE_GROUP_FACTORY.deployedByFactory(groupAvatar)) revert OnlyBaseGroupsAreSupported();

        address stableERC20CRC = IBaseMintHandler(IBaseGroup(groupAvatar).BASE_MINT_HANDLER()).INFLATIONARY();

        uint256 stableERC20CRCAmount = IERC20(stableERC20CRC).balanceOf(address(this));
        // wrap ERC1155 CRC into stable ERC20 CRC
        IHub(HUB_V2).wrap(groupAvatar, CRC_AMOUNT, uint8(1));
        stableERC20CRCAmount = IERC20(stableERC20CRC).balanceOf(address(this)) - stableERC20CRCAmount;

        // create the group LBP
        createGroupLBP(from, groupAvatar, stableERC20CRC, stableERC20CRCAmount);
        return this.onERC1155Received.selector;
    }
}
