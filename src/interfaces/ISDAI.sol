// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

interface ISDAI {
    function convertToShares(uint256 assets) external view returns (uint256);
}
