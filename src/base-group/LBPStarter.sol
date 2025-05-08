// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHub} from "src/interfaces/IHub.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {ILBP} from "src/interfaces/ILBP.sol";
import {IGroupLBPFactory} from "src/interfaces/base-group/IGroupLBPFactory.sol";

contract LBPStarter {
    /*//////////////////////////////////////////////////////////////
                             Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a function is called by any address that is not the Circles Hub v2.
    error OnlyHub();

    error OnlyGroup();

    error OnlyCreator();

    error NotCompletedYet();

    error AlreadyCompleted();

    error InsufficientBalance();

    /*//////////////////////////////////////////////////////////////
                           Constants
    //////////////////////////////////////////////////////////////*/

    /// @notice Circles Hub v2 contract address.
    IHub public constant HUB = IHub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));

    /// @notice Balancer V2 Vault contract address.
    address public constant VAULT = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    /// @notice The LBP Starter Factory.
    IGroupLBPFactory internal immutable FACTORY;

    address public immutable CREATOR;

    address public immutable GROUP;
    address public immutable ASSET;
    uint256 public immutable GROUP_AMOUNT;
    uint256 public immutable ASSET_AMOUNT;

    uint256 internal immutable INIT_WEIGHT_CRC;
    uint256 internal immutable INIT_WEIGHT_ASSET;
    uint256 internal immutable FINAL_WEIGHT_CRC;
    uint256 internal immutable FINAL_WEIGHT_ASSET;
    uint256 internal immutable SWAP_FEE;
    uint256 internal immutable UPDATE_WEIGHT_DURATION;
    address internal immutable STABLE_CRC;

    /*//////////////////////////////////////////////////////////////
                            Storage
    //////////////////////////////////////////////////////////////*/
    address public groupLBP;

    /*//////////////////////////////////////////////////////////////
                          Constructor
    //////////////////////////////////////////////////////////////*/

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

        // register org and trust id
        string memory lbpStarterName = string.concat(groupName, "-LBPStarter");
        HUB.registerOrganization(lbpStarterName, bytes32(0));
        HUB.trust(GROUP, type(uint96).max);
    }

    /*//////////////////////////////////////////////////////////////
                        Public Functions
    //////////////////////////////////////////////////////////////*/

    function createGroupLBP() public returns (address) {
        if (groupLBP != address(0)) revert AlreadyCompleted();
        if (balanceGroup() < GROUP_AMOUNT || balanceAsset() < ASSET_AMOUNT) {
            revert InsufficientBalance();
        }

        uint256 stableCRCAmount = IERC20(STABLE_CRC).balanceOf(address(this));
        // wrap ERC1155 CRC into stable ERC20 CRC
        HUB.wrap(GROUP, GROUP_AMOUNT, uint8(1));
        stableCRCAmount = IERC20(STABLE_CRC).balanceOf(address(this)) - stableCRCAmount;

        // Approve Vault to spend stable CRC
        IERC20(STABLE_CRC).approve(VAULT, stableCRCAmount);

        // Create LBP via Factory
        IVault.JoinPoolRequest memory request;

        (groupLBP, request) =
            FACTORY.createLBP(ASSET, STABLE_CRC, stableCRCAmount, ASSET_AMOUNT, INIT_WEIGHT_CRC, SWAP_FEE, GROUP);

        bytes32 poolId = ILBP(groupLBP).getPoolId();

        // Provide liquidity into the LBP and transfer BPT to creator
        IVault(VAULT).joinPool(poolId, address(this), CREATOR, request);

        // Gradually update weights for configured period
        uint256 finalUpdateTimestamp = block.timestamp + UPDATE_WEIGHT_DURATION;
        ILBP(groupLBP).updateWeightsGradually(block.timestamp, finalUpdateTimestamp, _finalWeights());

        return groupLBP;
    }

    function withdrawLeftovers() external {
        withdrawLeftovers(CREATOR);
    }

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

    function balanceGroup() public view returns (uint256 balance) {
        balance = HUB.balanceOf(address(this), uint256(uint160(GROUP)));
    }

    function balanceAsset() public view returns (uint256 balance) {
        balance = IERC20(ASSET).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                        Internal Functions
    //////////////////////////////////////////////////////////////*/

    function _finalWeights() internal view returns (uint256[] memory finalWeights) {
        bool crcZero = STABLE_CRC < ASSET;
        finalWeights = new uint256[](2);
        finalWeights[0] = crcZero ? FINAL_WEIGHT_CRC : FINAL_WEIGHT_ASSET;
        finalWeights[1] = crcZero ? FINAL_WEIGHT_ASSET : FINAL_WEIGHT_CRC;
    }

    /*//////////////////////////////////////////////////////////////
                           Callback
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC1155 callback invoked when the Circles Hub v2 transfers CRC tokens to this contract.
    /// @dev Accepts only specified Group CRC and in case the desired amounts are reached invokes LBP creation for it.
    /// @param id The CRC token ID, representing the numeric avatar address.
    /// @return The ERC1155Receiver selector to confirm receipt.
    function onERC1155Received(address, address, uint256 id, uint256, bytes calldata) external returns (bytes4) {
        if (msg.sender != address(HUB)) revert OnlyHub();
        if (id != uint256(uint160(GROUP))) revert OnlyGroup();
        if (groupLBP != address(0)) revert AlreadyCompleted();

        // invoke creation in case desired amounts are reached
        if (balanceGroup() >= GROUP_AMOUNT && balanceAsset() >= ASSET_AMOUNT) {
            createGroupLBP();
        }
        return this.onERC1155Received.selector;
    }
}
