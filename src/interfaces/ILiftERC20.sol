// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

interface ILiftERC20 {
    function erc20Circles(uint8 erc20Type, address avatar) external view returns (address);
}
