// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IHub} from "src/interfaces/IHub.sol";
import {Safe} from "safe-smart-account/contracts/Safe.sol";
import {Enum} from "safe-smart-account/contracts/common/Enum.sol";

/**
 * @title Test version of Safe Trust Module.
 * @notice Contract on Mint Policy request calls Hub from Safe to trust/untrust avatar.
 */
contract TestTrustModule {
    /// Safe `safe` has disabled this module.
    error ModuleDisabledBySafe(address safe);
    /// Attempt to execute trust/untrust failed during executionFromModule call.
    error ExecutionFromModuleFailed();
    /// Mint policy `mintPolicy` is missing approval from Safe `safe`.
    error MintPolicyNotApproved(address mintPolicy, address safe);

    /// @notice Emitted when safe trusts avatar by mint policy request.
    event Trust(address indexed avatar, address indexed safe, address indexed mintPolicy);
    /// @notice Emitted when safe untrusts avatar by mint policy request.
    event Untrust(address indexed avatar, address indexed safe, address indexed mintPolicy);

    /// @dev Maximum value for Hub trust expiration.
    uint96 internal constant INDEFINITE_FUTURE = type(uint96).max;

    /// @notice Circles Hub v2.
    address public constant HUB_V2 = address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8);

    mapping(address mintPolicy => Safe safe) public mintPolicyToSafe;
    mapping(address safe => address mintPolicy) public safeToMintPolicy;

    constructor() {}

    // Register logic

    /// @notice Allows Mint policy to set its Safe.
    function setSafe(address safe) external {
        mintPolicyToSafe[msg.sender] = Safe(payable(safe));
    }

    /// @notice Allows Safe to approve Mint policy.
    function approveMintPolicy(address mintPolicy) external {
        safeToMintPolicy[msg.sender] = mintPolicy;
    }

    // Trust logic

    /// @notice Allows mint policy to request Safe call to trust avatar.
    function trust(address avatar) external {
        Safe safe = _validateSafe();
        _executeTrustRequest(safe, avatar, INDEFINITE_FUTURE);
        emit Trust(avatar, address(safe), msg.sender);
    }

    /// @notice Allows mint policy to request Safe call to untrust avatar.
    function untrust(address avatar) external {
        Safe safe = _validateSafe();
        _executeTrustRequest(safe, avatar, uint96(block.timestamp));
        emit Untrust(avatar, address(safe), msg.sender);
    }

    // Internal functions

    function _validateSafe() internal view returns (Safe) {
        Safe safe = mintPolicyToSafe[msg.sender];
        if (safeToMintPolicy[address(safe)] != msg.sender) revert MintPolicyNotApproved(msg.sender, address(safe));
        if (!safe.isModuleEnabled(address(this))) revert ModuleDisabledBySafe(address(safe));
        return safe;
    }

    function _executeTrustRequest(Safe safe, address avatar, uint96 expiry) internal {
        bytes memory data = abi.encodeWithSelector(IHub.trust.selector, avatar, expiry);
        bool success = safe.execTransactionFromModule(HUB_V2, 0, data, Enum.Operation.Call);
        if (!success) revert ExecutionFromModuleFailed();
    }
}
