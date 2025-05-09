// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

interface IBaseMintHandler {
    function INFLATIONARY() external view returns (address erc20Address);
}
