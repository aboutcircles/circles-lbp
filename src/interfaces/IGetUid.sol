// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

interface IGetUid {
    function getUid(
        address sellToken,
        address buyToken,
        address receiver,
        uint256 sellAmount,
        uint256 buyAmount,
        uint32 validTo,
        bytes32 appData,
        uint256 feeAmount,
        bool isSell,
        bool partiallyFillable
    ) external view returns (bytes32 hash, bytes memory encoded);
}
