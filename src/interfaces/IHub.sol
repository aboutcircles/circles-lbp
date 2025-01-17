// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IHubV2} from "circles-contracts-v2/hub/IHub.sol";

interface IHub is IHubV2 {
    function inflationDayZero() external view returns (uint256);
    function trust(address _trustReceiver, uint96 _expiry) external;
    function personalMint() external;
    function registerHuman(address _inviter, bytes32 _metadataDigest) external;
    function registerGroup(address _mint, string calldata _name, string calldata _symbol, bytes32 _metadataDigest)
        external;
    function wrap(address _avatar, uint256 _amount, uint8 _type) external returns (address);
}
