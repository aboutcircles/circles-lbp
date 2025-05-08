// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IHubV2} from "circles-contracts-v2/hub/IHub.sol";

interface IHub is IHubV2 {
    function day(uint256 _timestamp) external view returns (uint64);
    function wrap(address _avatar, uint256 _amount, uint8 _type) external returns (address);
    function convertInflationaryToDemurrageValue(uint256 _inflationaryValue, uint64 _day)
        external
        pure
        returns (uint256);
    function convertDemurrageToInflationaryValue(uint256 _demurrageValue, uint64 _dayUpdated)
        external
        pure
        returns (uint256);
    function registerOrganization(string calldata _name, bytes32 _metadataDigest) external;
    function trust(address _trustReceiver, uint96 _expiry) external;
}
