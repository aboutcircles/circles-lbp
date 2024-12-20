// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CreateTestProxyLBPMintPolicy} from "src/proxy/CreateTestProxyLBPMintPolicy.sol";

contract MockImplementation {
    uint256 constant a = 1;
    uint256 public b;

    function initialize() external {
        require(b == 0);
        b = 1;
    }
}

contract MockSafe {
    function delegateTx(address to, bytes memory data) external {
        (bool success,) = address(to).delegatecall(data);
        require(success);
    }
}

event AdminChanged(address previousAdmin, address newAdmin);

contract CreateTestProxyLBPMintPolicyTest is Test {
    CreateTestProxyLBPMintPolicy public proxyDeployer;
    address public mockImplementation = address(new MockImplementation());

    function setUp() public {
        proxyDeployer = new CreateTestProxyLBPMintPolicy(mockImplementation);
    }

    function testFuzz_OnlyDelegateCall(address any) public {
        vm.expectRevert(CreateTestProxyLBPMintPolicy.OnlyDelegateCall.selector);
        vm.prank(any);
        proxyDeployer.createTestProxyMintPolicy();
    }

    function testCreateTestProxy() public {
        bytes memory data = abi.encodeWithSelector(CreateTestProxyLBPMintPolicy.createTestProxyMintPolicy.selector);
        _emitAdminChanged(address(this));
        (bool success,) = address(proxyDeployer).delegatecall(data);
        assertTrue(success);
    }

    function testFuzz_CreateTestProxy(address any) public {
        vm.prank(any);
        MockSafe safe = new MockSafe();
        bytes memory data = abi.encodeWithSelector(CreateTestProxyLBPMintPolicy.createTestProxyMintPolicy.selector);
        _emitAdminChanged(address(safe));
        vm.recordLogs();
        safe.delegateTx(address(proxyDeployer), data);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        address proxy = address(uint160(uint256(entries[2].topics[1])));
        console.log(proxy);
    }

    function _emitAdminChanged(address newAdmin) internal {
        vm.expectEmit(true, true, true, true);
        emit AdminChanged(address(0), newAdmin);
    }
}
