// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

interface ITestTrustModule {
    function setSafe(address safe) external;
    function approveMintPolicy(address mintPolicy) external;
    function trust(address avatar) external;
    function untrust(address avatar) external;
}
