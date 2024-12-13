// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {TypeDefinitions} from "circles-contracts-v2/hub/TypeDefinitions.sol";
import {BaseMintPolicyDefinitions} from "circles-contracts-v2/groups/Definitions.sol";

contract RedeemHelper {
    bytes32 public constant METADATATYPE_GROUPREDEEM = keccak256("CIRCLESv2:RESERVED_DATA:CirclesGroupRedeem");

    /// @notice Converts the user's redemption values, including avatars and amounts, into a byte format suitable for use in a safeTransferFrom call.
    function convertRedemptionToBytes(uint256[] memory redemptionIds, uint256[] memory redemptionValues)
        external
        pure
        returns (bytes memory data)
    {
        bytes memory userData =
            abi.encode(BaseMintPolicyDefinitions.BaseRedemptionPolicy(redemptionIds, redemptionValues));

        data = abi.encode(TypeDefinitions.Metadata(METADATATYPE_GROUPREDEEM, "", userData));
    }
}
