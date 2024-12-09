// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

interface ITestLBPMintPolicy {
    function TEST_CIRCLES_LBP_FACTORY() external view returns (address);
    function depositBPT(address user, address lbp) external;
}
