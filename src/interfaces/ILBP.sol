// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

interface ILBP {
    enum JoinKind {
        INIT,
        EXACT_TOKENS_IN_FOR_BPT_OUT,
        TOKEN_IN_FOR_EXACT_BPT_OUT
    }
    enum ExitKind {
        EXACT_BPT_IN_FOR_ONE_TOKEN_OUT,
        EXACT_BPT_IN_FOR_TOKENS_OUT,
        BPT_IN_FOR_EXACT_TOKENS_OUT
    }

    function getPoolId() external view returns (bytes32);
    function setSwapEnabled(bool swapEnabled) external;
    function updateWeightsGradually(uint256 startTime, uint256 endTime, uint256[] memory endWeights) external;
}
