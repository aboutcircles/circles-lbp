// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {UpgradeableRenounceableProxy} from "circles-contracts-v2/groups/UpgradeableRenounceableProxy.sol";

contract TestRenounceableProxy is UpgradeableRenounceableProxy {
    constructor(address implementation, bytes memory data) UpgradeableRenounceableProxy(implementation, data) {}
}
