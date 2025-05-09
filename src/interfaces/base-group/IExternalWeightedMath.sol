// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

/**
 * @notice Interface for ExternalWeightedMath, a contract-wrapper for Weighted Math, Joins and Exits.
 */
interface IExternalWeightedMath {
    /**
     * @dev See `WeightedMath._calculateInvariant`.
     */
    function calculateInvariant(uint256[] memory normalizedWeights, uint256[] memory balances)
        external
        pure
        returns (uint256);

    /**
     * @dev See `WeightedMath._calcOutGivenIn`.
     */
    function calcOutGivenIn(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountIn
    ) external pure returns (uint256);

    /**
     * @dev See `WeightedMath._calcInGivenOut`.
     */
    function calcInGivenOut(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountOut
    ) external pure returns (uint256);

    /**
     * @dev See `WeightedMath._calcBptOutGivenExactTokensIn`.
     */
    function calcBptOutGivenExactTokensIn(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsIn,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) external pure returns (uint256);

    /**
     * @dev See `WeightedMath._calcBptOutGivenExactTokenIn`.
     */
    function calcBptOutGivenExactTokenIn(
        uint256 balance,
        uint256 normalizedWeight,
        uint256 amountIn,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) external pure returns (uint256);

    /**
     * @dev See `WeightedMath._calcTokenInGivenExactBptOut`.
     */
    function calcTokenInGivenExactBptOut(
        uint256 balance,
        uint256 normalizedWeight,
        uint256 bptAmountOut,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) external pure returns (uint256);

    /**
     * @dev See `WeightedMath._calcAllTokensInGivenExactBptOut`.
     */
    function calcAllTokensInGivenExactBptOut(uint256[] memory balances, uint256 bptAmountOut, uint256 totalBPT)
        external
        pure
        returns (uint256[] memory);

    /**
     * @dev See `WeightedMath._calcBptInGivenExactTokensOut`.
     */
    function calcBptInGivenExactTokensOut(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsOut,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) external pure returns (uint256);

    /**
     * @dev See `WeightedMath._calcBptInGivenExactTokenOut`.
     */
    function calcBptInGivenExactTokenOut(
        uint256 balance,
        uint256 normalizedWeight,
        uint256 amountOut,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) external pure returns (uint256);

    /**
     * @dev See `WeightedMath._calcTokenOutGivenExactBptIn`.
     */
    function calcTokenOutGivenExactBptIn(
        uint256 balance,
        uint256 normalizedWeight,
        uint256 bptAmountIn,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) external pure returns (uint256);

    /**
     * @dev See `WeightedMath._calcTokensOutGivenExactBptIn`.
     */
    function calcTokensOutGivenExactBptIn(uint256[] memory balances, uint256 bptAmountIn, uint256 totalBPT)
        external
        pure
        returns (uint256[] memory);

    /**
     * @dev See `WeightedMath._calcBptOutAddToken`.
     */
    function calcBptOutAddToken(uint256 totalSupply, uint256 normalizedWeight) external pure returns (uint256);

    /**
     * @dev See `WeightedJoinsLib.joinExactTokensInForBPTOut`.
     */
    function joinExactTokensInForBPTOut(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory scalingFactors,
        uint256 totalSupply,
        uint256 swapFeePercentage,
        bytes memory userData
    ) external pure returns (uint256, uint256[] memory);

    /**
     * @dev See `WeightedJoinsLib.joinTokenInForExactBPTOut`.
     */
    function joinTokenInForExactBPTOut(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256 totalSupply,
        uint256 swapFeePercentage,
        bytes memory userData
    ) external pure returns (uint256, uint256[] memory);

    /**
     * @dev See `WeightedJoinsLib.joinAllTokensInForExactBPTOut`.
     */
    function joinAllTokensInForExactBPTOut(uint256[] memory balances, uint256 totalSupply, bytes memory userData)
        external
        pure
        returns (uint256 bptAmountOut, uint256[] memory amountsIn);

    /**
     * @dev See `WeightedExitsLib.exitExactBPTInForTokenOut`.
     */
    function exitExactBPTInForTokenOut(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256 totalSupply,
        uint256 swapFeePercentage,
        bytes memory userData
    ) external pure returns (uint256, uint256[] memory);

    /**
     * @dev See `WeightedExitsLib.exitExactBPTInForTokensOut`.
     */
    function exitExactBPTInForTokensOut(uint256[] memory balances, uint256 totalSupply, bytes memory userData)
        external
        pure
        returns (uint256 bptAmountIn, uint256[] memory amountsOut);

    /**
     * @dev See `WeightedExitsLib.exitBPTInForExactTokensOut`.
     */
    function exitBPTInForExactTokensOut(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory scalingFactors,
        uint256 totalSupply,
        uint256 swapFeePercentage,
        bytes memory userData
    ) external pure returns (uint256, uint256[] memory);
}
