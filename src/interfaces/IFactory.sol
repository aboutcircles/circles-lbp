// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

interface IFactory {
    function getAppData(address _circlesBackingInstance)
        external
        pure
        returns (string memory appDataString, bytes32 appDataHash);
}
