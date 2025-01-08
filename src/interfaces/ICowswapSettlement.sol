// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

interface ICowswapSettlement {
    function setPreSignature(bytes calldata orderUid, bool signed) external;
    function filledAmount(bytes calldata orderUid) external view returns (uint256);
}
