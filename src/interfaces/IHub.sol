// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IHubV2} from "circles-contracts-v2/hub/IHub.sol";

interface IHub is IHubV2 {
    function day(uint256 _timestamp) external view returns (uint64);
    function wrap(address _avatar, uint256 _amount, uint8 _type) external returns (address);
}
