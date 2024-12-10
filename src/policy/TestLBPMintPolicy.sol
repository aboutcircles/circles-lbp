// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {MintPolicy, IMintPolicy, BaseMintPolicyDefinitions} from "circles-contracts-v2/groups/BaseMintPolicy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {GroupDemurrage} from "src/policy/GroupDemurrage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITestTrustModule} from "src/interfaces/ITestTrustModule.sol";

/**
 * @title Test version of Liquidity Bootstraping Pool Mint Policy.
 * @notice Contract extends MintPolicy with LBP, allowing mints only to
 *         LBPFactory users and accounts their mints. BPT withdrawal is
 *         allowed only on zeroed mints.
 */
contract TestLBPMintPolicy is Initializable, GroupDemurrage, MintPolicy {
    /// Method can be called only by Hub contract.
    error OnlyHubV2();
    /// Method can be called only by StandardTreasury contract.
    error OnlyStandardTreasury();
    /// Method can be called only by CirclesLBPFactory contract.
    error OnlyCirclesLBPFactory();
    /// Requested group avatar by Hub doesn't match the group avatar this policy is attached to.
    error GroupAvatarMismatch();
    /// This `lbp` LBP is already set for this `user` user.
    error LBPAlreadySet(address user, address lbp);
    /// Before withdraw is required to redeem or burn minted group circle amount: `mintedAmount`.
    error MintedAmountNotZero(uint256 mintedAmount);

    /// @notice Emitted when a Balancer Pool Tokens are deposited to the policy.
    event BPTDeposit(address indexed user, address indexed lbp, uint256 indexed bptAmount);
    /// @notice Emitted when a Balancer Pool Tokens are withdrawn from the policy.
    event BPTWithdrawal(address indexed user, address indexed lbp, uint256 indexed bptAmount);

    struct LBP {
        address lbp;
        uint256 bptAmount;
    }

    /// @custom:storage-location erc7201:circles-test.storage.TestLBPMintPolicy
    struct TestLBPMintPolicyStorage {
        address groupAvatar;
        mapping(address user => LBP) lbps;
        mapping(address minter => DiscountedBalance) mintedAmounts;
    }

    // keccak256(abi.encode(uint256(keccak256("circles-test.storage.TestLBPMintPolicy")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TestLBPMintPolicyStorageLocation =
        0xca29e300055a7452862813c656216e9b6f0fc137dc564e51d7176af282c11600;

    /// @notice Circles Hub v2.
    address public constant HUB_V2 = address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8);
    /// @notice Circles v2 StandardTreasury.
    address public constant STANDARD_TREASURY = address(0x08F90aB73A515308f03A718257ff9887ED330C6e);
    /// @notice Test version of CirclesLBPFactory.
    address public constant TEST_CIRCLES_LBP_FACTORY = address(0x97030b525248cAc78aabcc33D37139BfB5a34750);
    /// @notice Test version of TrustModule.
    ITestTrustModule public constant TEST_TRUST_MODULE =
        ITestTrustModule(address(0x56652E53649F20C6a360Ea5F25379F9987cECE82));

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        TestLBPMintPolicyStorage storage $ = _getTestLBPMintPolicyStorage();
        $.groupAvatar = msg.sender;
        TEST_TRUST_MODULE.setSafe(msg.sender);
    }

    // Hub Mint Policy logic

    /**
     * @notice Before mint checks and allows to mint only if user has lbp, accounts minted amount
     */
    function beforeMintPolicy(
        address minter,
        address group,
        uint256[] calldata, /*_collateral*/
        uint256[] calldata amounts,
        bytes calldata /*_data*/
    ) external virtual override returns (bool) {
        _onlyHubV2();
        _checkGroupAvatar(group);
        // mint is allowed only for lbp factory users
        if (_getBPTAmount(minter) == 0) return false;
        // account minted amount
        uint256 totalAmount;
        for (uint256 i; i < amounts.length;) {
            totalAmount += amounts[i];
            unchecked {
                ++i;
            }
        }
        _accountMintedAmount(minter, totalAmount, true);
        return true;
    }

    /**
     * @notice Simple burn policy that always returns true and accounts burn for LBP user
     */
    function beforeBurnPolicy(address burner, address group, uint256 amount, bytes calldata)
        external
        virtual
        override
        returns (bool)
    {
        _onlyHubV2();
        _checkGroupAvatar(group);
        if (_getBPTAmount(burner) > 0) {
            _accountMintedAmount(burner, amount, false);
        }
        return true;
    }

    /**
     * @notice Simple redeem policy that returns the redemption ids and values as requested in the data
     *         Accounts redeem in minted amount for LBP user.
     * @param _data Optional data bytes passed to redeem policy
     */
    function beforeRedeemPolicy(
        address, /* operator */
        address redeemer,
        address group,
        uint256 value,
        bytes calldata _data
    )
        external
        virtual
        override
        returns (
            uint256[] memory _ids,
            uint256[] memory _values,
            uint256[] memory _burnIds,
            uint256[] memory _burnValues
        )
    {
        if (msg.sender != STANDARD_TREASURY) revert OnlyStandardTreasury();
        _checkGroupAvatar(group);
        if (_getBPTAmount(redeemer) > 0) {
            _accountMintedAmount(redeemer, value, false);
        }

        // simplest policy is to return the collateral as the caller requests it in data
        BaseMintPolicyDefinitions.BaseRedemptionPolicy memory redemption =
            abi.decode(_data, (BaseMintPolicyDefinitions.BaseRedemptionPolicy));

        // and no collateral gets burnt upon redemption
        _burnIds = new uint256[](0);
        _burnValues = new uint256[](0);

        // standard treasury checks whether the total sums add up to the amount of group Circles redeemed
        // so we can simply decode and pass the request back to treasury.
        // The redemption will fail if it does not contain (sufficient of) these Circles
        return (redemption.redemptionIds, redemption.redemptionValues, _burnIds, _burnValues);
    }

    // LBP Factory logic

    /**
     * @notice Method should be called by CirclesLBPFactory after LBP onJoinPool with BPT recipient address(this).
     *         Accounts BPT deposit and allows user to mint group token.
     *         Asks group to trust user avatar as a group collateral.
     */
    function depositBPT(address user, address lbp) external {
        if (msg.sender != TEST_CIRCLES_LBP_FACTORY) revert OnlyCirclesLBPFactory();
        if (_getBPTAmount(user) > 0) revert LBPAlreadySet(user, lbp);
        // bpt amount should be transfered before this call by factory
        uint256 bptAmount = IERC20(lbp).balanceOf(address(this));
        _setLBP(user, lbp, bptAmount);
        emit BPTDeposit(user, lbp, bptAmount);
        // safe.module try groupAvatar trust user
        try TEST_TRUST_MODULE.trust(user) {} catch {}
    }

    /**
     * @notice Method allows LBP user to withdraw Balancer Pool Tokens related to LBP only
     *         if user current minted group CRC amount is zero.
     *         Accounts BPT withdrawal and disallows user to mint group token.
     *         Asks group to untrust user avatar as a group collateral.
     */
    function withdrawBPT() external {
        address user = msg.sender;
        uint256 mintedAmountOnToday;
        (mintedAmountOnToday,) = _getMintedAmountOnToday(user);
        if (mintedAmountOnToday != 0) revert MintedAmountNotZero(mintedAmountOnToday);

        address lbp = _getLBPAddress(user);
        uint256 bptAmount = _getBPTAmount(user);
        _setLBP(user, lbp, 0);
        IERC20(lbp).transfer(user, bptAmount);
        emit BPTWithdrawal(user, lbp, bptAmount);
        // safe.module try groupAvatar untrust user
        try TEST_TRUST_MODULE.untrust(user) {} catch {}
    }

    // View functions

    function getGroupAvatar() external view returns (address) {
        return _getGroupAvatar();
    }

    function getBPTAmount(address user) external view returns (uint256) {
        return _getBPTAmount(user);
    }

    function getLBPAddress(address user) external view returns (address) {
        return _getLBPAddress(user);
    }

    function getMintedAmount(address user) external view returns (uint256 mintedAmount) {
        (mintedAmount,) = _getMintedAmountOnToday(user);
    }

    // Internal functions

    function _onlyHubV2() internal view {
        if (msg.sender != HUB_V2) revert OnlyHubV2();
    }

    function _checkGroupAvatar(address group) internal view {
        if (group != _getGroupAvatar()) revert GroupAvatarMismatch();
    }

    function _accountMintedAmount(address minter, uint256 amount, bool add) internal {
        (uint256 mintedAmountOnToday, uint64 today) = _getMintedAmountOnToday(minter);
        uint256 updatedBalance;
        if (add) {
            updatedBalance = mintedAmountOnToday + amount;
            require(updatedBalance <= MAX_VALUE);
        } else if (amount < mintedAmountOnToday) {
            updatedBalance = mintedAmountOnToday - amount;
        }
        _setMintedAmount(minter, uint192(updatedBalance), today);
    }

    function _getMintedAmountOnToday(address user) internal view returns (uint256 mintedAmountOnToday, uint64 today) {
        DiscountedBalance memory discountedBalance = _getMintedAmount(user);
        today = day(block.timestamp);
        mintedAmountOnToday =
            _calculateDiscountedBalance(discountedBalance.balance, today - discountedBalance.lastUpdatedDay);
    }

    // Private functions

    function _getTestLBPMintPolicyStorage() private pure returns (TestLBPMintPolicyStorage storage $) {
        assembly {
            $.slot := TestLBPMintPolicyStorageLocation
        }
    }

    function _getGroupAvatar() private view returns (address) {
        TestLBPMintPolicyStorage storage $ = _getTestLBPMintPolicyStorage();
        return $.groupAvatar;
    }

    function _getBPTAmount(address user) private view returns (uint256) {
        TestLBPMintPolicyStorage storage $ = _getTestLBPMintPolicyStorage();
        return $.lbps[user].bptAmount;
    }

    function _getLBPAddress(address user) private view returns (address) {
        TestLBPMintPolicyStorage storage $ = _getTestLBPMintPolicyStorage();
        return $.lbps[user].lbp;
    }

    function _setLBP(address user, address lbp_, uint256 bptAmount_) private {
        TestLBPMintPolicyStorage storage $ = _getTestLBPMintPolicyStorage();
        $.lbps[user] = LBP({lbp: lbp_, bptAmount: bptAmount_});
    }

    function _getMintedAmount(address minter) private view returns (DiscountedBalance memory) {
        TestLBPMintPolicyStorage storage $ = _getTestLBPMintPolicyStorage();
        return $.mintedAmounts[minter];
    }

    function _setMintedAmount(address minter, uint192 amount, uint64 day) private {
        TestLBPMintPolicyStorage storage $ = _getTestLBPMintPolicyStorage();
        $.mintedAmounts[minter] = DiscountedBalance({balance: amount, lastUpdatedDay: day});
    }
}
