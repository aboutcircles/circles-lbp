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

/**
 * @title Group LBP Factory
 */
contract GroupLBPFactory {
    /*//////////////////////////////////////////////////////////////
                             Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a function is called by any address that is not the HubV2.
    error OnlyHub();

    /// @notice Thrown when the received CRC amount does not match the exact required CRC amount.
    /// @param required The required CRC amount.
    /// @param received The actual CRC amount received.
    error NotExactlyRequiredCRCAmount(uint256 required, uint256 received);

    /// @notice Thrown when the process is attempted for a non-base-group avatar address in the Hub.
    error OnlyBaseGroupsAreSupported();

    error OnlyOneLBPPerGroup();

    /// @notice Thrown when trying to exit from an Balances pool that does not contain exactly two tokens.
    error OnlyTwoTokenLBPSupported();

    /*//////////////////////////////////////////////////////////////
                             Events
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a group LBP creation process is completed.
     * @param creator The address, which created LBP and submitted required liquidity.
     * @param group The group for which LBP was created.
     * @param lbp The newly created LBP address.
     */
    event GroupLBPCreated(address indexed creator, address indexed group, address indexed lbp);

    /*//////////////////////////////////////////////////////////////
                           Constants
    //////////////////////////////////////////////////////////////*/

    /// @notice Circles Hub v2.
    address public constant HUB_V2 = address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8);

    IBaseGroupFactory public constant BASE_GROUP_FACTORY =
        IBaseGroupFactory(address(0xD0B5Bd9962197BEaC4cbA24244ec3587f19Bd06d));

    /// @notice Balancer v2 LBPFactory address.
    INoProtocolFeeLiquidityBootstrappingPoolFactory public constant LBP_FACTORY =
        INoProtocolFeeLiquidityBootstrappingPoolFactory(address(0x85a80afee867aDf27B50BdB7b76DA70f1E853062));

    /// @notice Balancer v2 Vault address.
    address public constant VAULT = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    /// @notice sDAI contract address on Gnosis Chain.
    address public constant SDAI = 0xaf204776c7245bF4147c2612BF6e5972Ee483701;

    /// @notice Amount denominated in xDAI to use in a sDAI calculation for pool liquidity.
    uint256 public constant STABLE_AMOUNT = 1_000 ether;

    /// @notice Amount of group Circles (ERC1155) to use in LBP initial liquidity.
    uint256 public constant CRC_AMOUNT = 480 ether;

    /// @dev LBP group CRC token weight 1%.
    uint256 internal constant WEIGHT_CRC = 0.01 ether;

    /// @dev LBP sDAI token weight 99%.
    uint256 internal constant WEIGHT_SDAI = 0.99 ether;

    /// @notice LBP tokens final weight 50%.
    uint256 internal constant WEIGHT_FINAL = 0.5 ether;

    /// @notice Token weight update duration set to 60 days.
    uint256 internal constant UPDATE_WEIGHT_DURATION = 60 days;

    /// @dev Swap fee percentage is set to 1% for the LBP.
    uint256 internal constant SWAP_FEE = 0.01 ether;

    /// @dev BPT name and symbol prefix for LBPs created in this factory.
    string internal constant LBP_PREFIX = "groupLBP-";

    /*//////////////////////////////////////////////////////////////
                            Storage
    //////////////////////////////////////////////////////////////*/

    mapping(address creator => mapping(address group => address lbp)) public lbpOf;

    mapping(address lbp => address creator) public lbpCreator;

    mapping(address lbp => address group) public lbpGroup;

    /*//////////////////////////////////////////////////////////////
                            Modifiers
    //////////////////////////////////////////////////////////////*/

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
     * @notice Initializes the GroupLBPFactory.
     */
    constructor() {}

    /*//////////////////////////////////////////////////////////////
                          LBP Creation Logic
    //////////////////////////////////////////////////////////////*/

    /// @dev requires sDAI preapproval
    function createGroupLBP(address creator, address group, address stableCRCAddress, uint256 stableCRCAmount)
        internal
    {
        if (lbpOf[creator][group] != address(0)) revert OnlyOneLBPPerGroup();

        uint256 sDAIEquivalent = ISDAI(SDAI).convertToShares(STABLE_AMOUNT);
        // transfer sDAI equivalent of STABLE_AMOUNT from creator
        IERC20(SDAI).transferFrom(creator, address(this), sDAIEquivalent);

        // Prepare the tokens array for Balancer
        IERC20[] memory tokens = new IERC20[](2);
        bool tokenZero = stableCRCAddress < SDAI;
        tokens[0] = tokenZero ? IERC20(stableCRCAddress) : IERC20(SDAI);
        tokens[1] = tokenZero ? IERC20(SDAI) : IERC20(stableCRCAddress);

        // Create the LBP
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

        // Prepare amountsIn
        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = tokenZero ? stableCRCAmount : sDAIEquivalent;
        amountsIn[1] = tokenZero ? sDAIEquivalent : stableCRCAmount;

        // Encode the userData needed for Balancer
        bytes memory userData = abi.encode(ILBP.JoinKind.INIT, amountsIn);
        IVault.JoinPoolRequest memory request = IVault.JoinPoolRequest(tokens, amountsIn, userData, false);

        // Approve Vault to spend stable CRC and sDAI
        IERC20(stableCRCAddress).approve(VAULT, stableCRCAmount);
        IERC20(SDAI).approve(VAULT, sDAIEquivalent);

        // Provide liquidity into the LBP and set creator as BPT recipient
        IVault(VAULT).joinPool(poolId, address(this), creator, request);

        // Gradually update weights
        uint256 timestampWeightUpdate = block.timestamp + UPDATE_WEIGHT_DURATION;
        ILBP(lbp).updateWeightsGradually(block.timestamp, timestampWeightUpdate, _endWeights());

        // link creator and group to lbp
        lbpOf[creator][group] = lbp;
        // link lbp to creator
        lbpCreator[lbp] = creator;
        // link lbp to group
        lbpGroup[lbp] = group;

        emit GroupLBPCreated(creator, group, lbp);
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

    /*//////////////////////////////////////////////////////////////
                         Internal Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Constructs the name for a newly created LBP based on the name of the CRC.
     * @param inflationaryCirlces The stable ERC20 CRC token address.
     * @return The constructed LBP name.
     */
    function _name(address inflationaryCirlces) internal view returns (string memory) {
        return string(abi.encodePacked(LBP_PREFIX, IERC20Metadata(inflationaryCirlces).name()));
    }

    /**
     * @dev Constructs the symbol for a newly created LBP based on the symbol of the CRC.
     * @param inflationaryCirlces The stable ERC20 CRC token address.
     * @return The constructed LBP symbol.
     */
    function _symbol(address inflationaryCirlces) internal view returns (string memory) {
        return string(abi.encodePacked(LBP_PREFIX, IERC20Metadata(inflationaryCirlces).symbol()));
    }

    function _initWeights(bool tokenZero) internal pure returns (uint256[] memory initWeights) {
        // Set initial weights
        initWeights = new uint256[](2);
        initWeights[0] = tokenZero ? WEIGHT_CRC : WEIGHT_SDAI;
        initWeights[1] = tokenZero ? WEIGHT_SDAI : WEIGHT_CRC;
    }

    /**
     * @notice Returns the end weights array for the LBP (both 50%).
     * @return endWeights An array containing end weights for stable CRC and sDAI.
     */
    function _endWeights() internal pure returns (uint256[] memory endWeights) {
        endWeights = new uint256[](2);
        endWeights[0] = WEIGHT_FINAL;
        endWeights[1] = WEIGHT_FINAL;
    }

    /*//////////////////////////////////////////////////////////////
                           Callback
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice ERC1155 callback invoked when HubV2 transfers CRC tokens to this contract.
     * @dev This function ensures that:
     *      1. The caller is HubV2.
     *      2. The correct CRC amount (480 CRC) is transferred.
     *      3. The avatar is base group.
     *      4. Wraps CRC into stable CRC and initiates the LBP creation process.
     * @param from The address from which CRC tokens are sent.
     * @param id The CRC token ID, which is the numeric representation of the avatar address.
     * @param value The amount of CRC tokens transferred.
     * @param data Encoded (tbd).
     * @return The function selector to confirm the ERC1155 receive operation.
     */
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
