// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

interface IBaseGroupFactory {
    function deployedByFactory(address group) external view returns (bool);
}
