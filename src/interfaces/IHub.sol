// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.24;

import {IHubV2} from "circles-contracts-v2/hub/IHub.sol";

interface IHub is IHubV2 {
    function inflationDayZero() external view returns (uint256);
}
