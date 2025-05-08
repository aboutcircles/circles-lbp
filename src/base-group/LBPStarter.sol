// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {ILBP} from "src/interfaces/ILBP.sol";
import {IGroupLBPFactory} from "src/interfaces/base-group/IGroupLBPFactory.sol";

/// @title LBPStarter
/// @notice Deploys and initializes a Liquidity Bootstrapping Pool (LBP) for a given Group CRC and asset pair.
contract LBPStarter {
    /*//////////////////////////////////////////////////////////////
                             Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a function is called by any address that is not the Circles Hub v2.
    error OnlyHub();

    /// @notice Thrown when a function is called with an unexpected Group CRC ID.
    error OnlyGroup();

    /// @notice Thrown when a function is called by anyone other than the configured creator.
    error OnlyCreator();

    /// @notice Thrown when attempting an action before the LBP creation is complete.
    error NotCompletedYet();

    /// @notice Thrown when attempting to create the LBP more than once.
    error AlreadyCompleted();

    /// @notice Thrown when the contract holds insufficient balance of either Group CRC or asset.
    error InsufficientBalance();

    /*//////////////////////////////////////////////////////////////
                           Constants
    //////////////////////////////////////////////////////////////*/

    /// @notice Circles Hub v2 contract address.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    /// @notice Balancer V2 Vault contract address.
    address public constant VAULT = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    /// @notice The LBP Starter Factory that deployed this contract.
    IGroupLBPFactory internal immutable FACTORY;

    /// @notice Address of the creator who receives BPT and leftover tokens.
    address public immutable CREATOR;

    /// @notice CRC group address (eq. ERC1155 token ID).
    address public immutable GROUP;

    /// @notice ERC20 asset to be pooled alongside the CRC group.
    address public immutable ASSET;

    /// @notice Amount of Group CRC tokens to deposit into the pool.
    uint256 public immutable GROUP_AMOUNT;

    /// @notice Amount of asset tokens to deposit into the pool.
    uint256 public immutable ASSET_AMOUNT;

    /// @dev Initial CRC weight (in wei units, 1e18 == 100%).
    uint256 internal immutable INIT_WEIGHT_CRC;

    /// @dev Derived initial asset weight (1 ether - INIT_WEIGHT_CRC).
    uint256 internal immutable INIT_WEIGHT_ASSET;

    /// @dev Final CRC weight (in wei units).
    uint256 internal immutable FINAL_WEIGHT_CRC;

    /// @dev Derived final asset weight (1 ether - FINAL_WEIGHT_CRC).
    uint256 internal immutable FINAL_WEIGHT_ASSET;

    /// @notice Swap fee percentage for the LBP, in wei units.
    uint256 internal immutable SWAP_FEE;

    /// @notice Duration over which weights are linearly updated, in seconds.
    uint256 internal immutable UPDATE_WEIGHT_DURATION;

    /// @notice Address of the stable ERC20 CRC token used for pooling.
    address internal immutable STABLE_CRC;

    /*//////////////////////////////////////////////////////////////
                            Storage
    //////////////////////////////////////////////////////////////*/

    /// @notice Address of the deployed Group LBP pool.
    address public groupLBP;

    /*//////////////////////////////////////////////////////////////
                          Constructor
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the starter with configuration parameters and registers on the Hub.
    /// @param creator The address that will receive BPT and leftover tokens.
    /// @param group The CRC group address (eq. ERC1155 token ID) to wrap and pool.
    /// @param asset The ERC20 asset to pool against the CRC group.
    /// @param groupAmount The amount of group CRC to wrap and deposit.
    /// @param assetAmount The amount of asset tokens to deposit.
    /// @param groupInitWeight The initial weight for CRC in the pool (in wei).
    /// @param groupFinalWeight The final weight for CRC in the pool (in wei).
    /// @param swapFee The swap fee for the pool (in wei).
    /// @param updateWeightDuration Time period over which to update pool weights (seconds).
    /// @param stableERC20CRC Address of the ERC20-wrapped CRC token.
    /// @param groupName Human-readable name of the CRC group.
    constructor(
        address creator,
        address group,
        address asset,
        uint256 groupAmount,
        uint256 assetAmount,
        uint256 groupInitWeight,
        uint256 groupFinalWeight,
        uint256 swapFee,
        uint256 updateWeightDuration,
        address stableERC20CRC,
        string memory groupName
    ) {
        CREATOR = creator;
        GROUP = group;
        ASSET = asset;
        GROUP_AMOUNT = groupAmount;
        ASSET_AMOUNT = assetAmount;
        INIT_WEIGHT_CRC = groupInitWeight;
        INIT_WEIGHT_ASSET = 1 ether - groupInitWeight;
        FINAL_WEIGHT_CRC = groupFinalWeight;
        FINAL_WEIGHT_ASSET = 1 ether - groupFinalWeight;
        SWAP_FEE = swapFee;
        UPDATE_WEIGHT_DURATION = updateWeightDuration;
        STABLE_CRC = stableERC20CRC;

        FACTORY = IGroupLBPFactory(msg.sender);

        // Approve Vault to spend asset
        IERC20(ASSET).approve(VAULT, ASSET_AMOUNT);

        // Register this starter as an organization and trust the group on the Hub.
        string memory lbpStarterName = string.concat(groupName, "-LBPStarter");
        HUB.registerOrganization(lbpStarterName, bytes32(0));
        HUB.trust(GROUP, type(uint96).max);
    }

    /*//////////////////////////////////////////////////////////////
                        Public Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates the Group LBP, supplies initial liquidity, and schedules weight updates.
    /// @dev Can only be called once and requires sufficient Group and asset balances.
    /// @return The address of the newly created LBP contract.
    function createGroupLBP() public returns (address) {
        if (groupLBP != address(0)) revert AlreadyCompleted();
        if (balanceGroup() < GROUP_AMOUNT || balanceAsset() < ASSET_AMOUNT) {
            revert InsufficientBalance();
        }

        uint256 stableCRCAmount = IERC20(STABLE_CRC).balanceOf(address(this));
        // Wrap ERC1155 CRC into stable ERC20 CRC
        HUB.wrap(GROUP, GROUP_AMOUNT, uint8(1));
        stableCRCAmount = IERC20(STABLE_CRC).balanceOf(address(this)) - stableCRCAmount;

        // Approve Vault to spend stable CRC
        IERC20(STABLE_CRC).approve(VAULT, stableCRCAmount);

        // Create LBP via Factory and prepare join request
        IVault.JoinPoolRequest memory request;
        (groupLBP, request) =
            FACTORY.createLBP(ASSET, STABLE_CRC, stableCRCAmount, ASSET_AMOUNT, INIT_WEIGHT_CRC, SWAP_FEE, GROUP);

        bytes32 poolId = ILBP(groupLBP).getPoolId();

        // Provide liquidity into the LBP and transfer BPT tokens to the creator
        IVault(VAULT).joinPool(poolId, address(this), CREATOR, request);

        // Schedule gradual weight updates over the configured duration
        uint256 finalUpdateTimestamp = block.timestamp + UPDATE_WEIGHT_DURATION;
        ILBP(groupLBP).updateWeightsGradually(block.timestamp, finalUpdateTimestamp, _finalWeights());

        return groupLBP;
    }

    /// @notice Withdraws any leftover Group CRC and asset tokens to the creator.
    function withdrawLeftovers() external {
        withdrawLeftovers(CREATOR);
    }

    /// @notice Withdraws any leftover Group CRC and asset tokens to a specified destination by the creator.
    /// @param destination The address to receive leftover tokens.
    function withdrawLeftovers(address destination) public {
        if (msg.sender != CREATOR) revert OnlyCreator();
        if (groupLBP == address(0)) revert NotCompletedYet();
        uint256 balance = balanceGroup();
        if (balance > 0) HUB.safeTransferFrom(address(this), destination, uint256(uint160(GROUP)), balance, "");
        balance = balanceAsset();
        if (balance > 0) IERC20(ASSET).transfer(destination, balance);
    }

    /*//////////////////////////////////////////////////////////////
                        View Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns configuration: the initial and final weights, swap fee, and update duration of the LBP.
    /// @return initWeightCRC Initial CRC weight.
    /// @return initWeightAsset Initial asset weight.
    /// @return finalWeightCRC Final CRC weight.
    /// @return finalWeightAsset Final asset weight.
    /// @return swapFee Swap fee in wei.
    /// @return updateWeightDuration Weight update duration in seconds.
    function lbpConfiguration()
        external
        view
        returns (
            uint256 initWeightCRC,
            uint256 initWeightAsset,
            uint256 finalWeightCRC,
            uint256 finalWeightAsset,
            uint256 swapFee,
            uint256 updateWeightDuration
        )
    {
        (initWeightCRC, initWeightAsset, finalWeightCRC, finalWeightAsset, swapFee, updateWeightDuration) =
            (INIT_WEIGHT_CRC, INIT_WEIGHT_ASSET, FINAL_WEIGHT_CRC, FINAL_WEIGHT_ASSET, SWAP_FEE, UPDATE_WEIGHT_DURATION);
    }

    /// @notice Returns the contract's current balance of Group CRC tokens.
    /// @return balance The Group CRC token balance.
    function balanceGroup() public view returns (uint256 balance) {
        balance = HUB.balanceOf(address(this), uint256(uint160(GROUP)));
    }

    /// @notice Returns the contract's current balance of asset tokens.
    /// @return balance The asset token balance.
    function balanceAsset() public view returns (uint256 balance) {
        balance = IERC20(ASSET).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                        Internal Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Computes the final weight array for the CRC and asset tokens.
    /// @return finalWeights An array of two weights [CRC weight, asset weight].
    function _finalWeights() internal view returns (uint256[] memory finalWeights) {
        bool crcZero = STABLE_CRC < ASSET;
        finalWeights = new uint256[](2);
        finalWeights[0] = crcZero ? FINAL_WEIGHT_CRC : FINAL_WEIGHT_ASSET;
        finalWeights[1] = crcZero ? FINAL_WEIGHT_ASSET : FINAL_WEIGHT_CRC;
    }

    /*//////////////////////////////////////////////////////////////
                           Callback
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC1155 callback invoked when the Circles Hub v2 transfers CRC tokens.
    /// @dev Accepts only the specified Group CRC and triggers LBP creation when targets are met.
    /// @param id The CRC token ID being transferred.
    /// @return The ERC1155Receiver selector to confirm receipt.
    function onERC1155Received(address, address, uint256 id, uint256, bytes calldata) external returns (bytes4) {
        if (msg.sender != address(HUB)) revert OnlyHub();
        if (id != uint256(uint160(GROUP))) revert OnlyGroup();
        if (groupLBP != address(0)) revert AlreadyCompleted();

        // Automatically create the pool when required deposits are received
        if (balanceGroup() >= GROUP_AMOUNT && balanceAsset() >= ASSET_AMOUNT) {
            createGroupLBP();
        }
        return this.onERC1155Received.selector;
    }
}
