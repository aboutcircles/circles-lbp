// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TestTrustModule} from "src/module/TestTrustModule.sol";
import {TestCirclesLBPFactory} from "src/factory/TestCirclesLBPFactory.sol";
import {TestLBPMintPolicy} from "src/policy/TestLBPMintPolicy.sol";
import {CreateTestProxyLBPMintPolicy} from "src/proxy/CreateTestProxyLBPMintPolicy.sol";
import {Safe} from "safe-smart-account/contracts/Safe.sol";
import {Enum} from "safe-smart-account/contracts/common/Enum.sol";
import {ModuleManager} from "safe-smart-account/contracts/base/ModuleManager.sol";
import {Hub} from "circles-contracts-v2/hub/Hub.sol";
import {CirclesType} from "circles-contracts-v2/lift/IERC20Lift.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DepositFlowTest is Test {
    uint256 blockNumber = 37_456_676;
    uint256 gnosis;
    // deployment
    address public constant STANDARD_TREASURY = address(0x08F90aB73A515308f03A718257ff9887ED330C6e);
    Hub public hub = Hub(address(0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8));
    TestTrustModule public trustModule = TestTrustModule(address(0x56652E53649F20C6a360Ea5F25379F9987cECE82));
    TestCirclesLBPFactory public circlesLBPFactory =
        TestCirclesLBPFactory(address(0x97030b525248cAc78aabcc33D37139BfB5a34750));
    address public implementationLBPMintPolicy = address(0xCb10eC7A4D9D764b1DcfcB9c2EBa675B1e756C96);
    CreateTestProxyLBPMintPolicy public proxyDeployer =
        CreateTestProxyLBPMintPolicy(address(0x777f78921890Df5Db755e77CbA84CBAdA5DB56D2));
    // test values
    Safe testGroupSafe = Safe(payable(address(0x8bD2e75661Af98037b1Fc9fa0f9435baAa6Dd5ac)));
    address proxy;
    address testAccount = address(0x2A6878e8e34647533C5AA46012008ABfdF496988);

    function setUp() public {
        gnosis = vm.createFork(vm.envString("GNOSIS_RPC"), blockNumber);
        vm.selectFork(gnosis);

        // 1. first setup step for a TestGroup is to deploy proxy by Safe (requires crafting signatures):
        // delegatecall from Safe to proxyDeployer
        bytes memory data = abi.encodeWithSelector(CreateTestProxyLBPMintPolicy.createTestProxyMintPolicy.selector);
        vm.recordLogs();
        _executeSafeTx(testGroupSafe, address(proxyDeployer), data, Enum.Operation.DelegateCall);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        proxy = address(uint160(uint256(entries[5].topics[1])));

        // 2. second setup step for a TestGroup is to approve mint policy in TrustModule and enable TrustModule

        // call approve mint policy (proxy)
        data = abi.encodeWithSelector(TestTrustModule.approveMintPolicy.selector, proxy);
        _executeSafeTx(testGroupSafe, address(trustModule), data, Enum.Operation.Call);

        // call enableModule() on Safe to enable TrustModule
        data = abi.encodeWithSelector(ModuleManager.enableModule.selector, address(trustModule));
        _executeSafeTx(testGroupSafe, address(testGroupSafe), data, Enum.Operation.Call);

        // 3. third setup step for a TestGroup is to registerGroup in Hub with proxy as a mint policy
        data = abi.encodeWithSelector(Hub.registerGroup.selector, proxy, "testGroup", "TG", bytes32(0));
        _executeSafeTx(testGroupSafe, address(hub), data, Enum.Operation.Call);
    }

    function testDepositFlow() public {
        _createLBPGroupMint();
    }

    function testWithdrawSameTimestampMint() public {
        _createLBPGroupMint();
        // 1. redeem collateral group
        //bytes memory data = abi.encode();
        //vm.prank(testAccount);
        //hub.safeTransferFrom(testAccount, STANDARD_TREASURY, uint256(uint160(address(testGroupSafe))), 10 ether, "");
        address lbp = TestLBPMintPolicy(proxy).getLBPAddress(testAccount);
        // 2. burn group token
        vm.prank(testAccount);
        hub.burn(uint256(uint160(address(testGroupSafe))), 10 ether, "");

        vm.prank(testAccount);
        TestLBPMintPolicy(proxy).withdrawBPT();

        // 3. withdraw liquidity
        uint256 balance = IERC20(lbp).balanceOf(testAccount);
        vm.prank(testAccount);
        IERC20(lbp).approve(address(circlesLBPFactory), balance);
        vm.prank(testAccount);
        circlesLBPFactory.exitLBP(lbp, balance);
    }

    function testWithdrawAfterDurationMint() public {
        _createLBPGroupMint();
        uint256 amount = 9980150952490564255; // 9996027034861687221
        uint256 duration = 10 days; // 2 days
        _withdrawAfter(duration, amount);
    }

    // Internal helpers

    function _withdrawAfter(uint256 duration, uint256 amount) internal {
        vm.warp(block.timestamp + duration);
        // 1. redeem collateral group
        //bytes memory data = abi.encode();
        //vm.prank(testAccount);
        //hub.safeTransferFrom(testAccount, STANDARD_TREASURY, uint256(uint160(address(testGroupSafe))), 10 ether, "");
        address lbp = TestLBPMintPolicy(proxy).getLBPAddress(testAccount);
        // 2. burn group token
        vm.prank(testAccount);
        hub.burn(uint256(uint160(address(testGroupSafe))), amount, "");

        vm.prank(testAccount);
        TestLBPMintPolicy(proxy).withdrawBPT();

        // 3. withdraw liquidity
        uint256 balance = IERC20(lbp).balanceOf(testAccount);
        vm.prank(testAccount);
        IERC20(lbp).approve(address(circlesLBPFactory), balance);
        vm.prank(testAccount);
        circlesLBPFactory.exitLBP(lbp, balance);
    }

    function _createLBPGroupMint() internal {
        // 1. avatar should wrap into Inflationary CRC
        vm.prank(testAccount);
        address inflationaryCRC = hub.wrap(testAccount, 37971397492393667509, CirclesType.Inflation);
        // 2. approve LBP factory to spend 48 InflCRC
        vm.prank(testAccount);
        IERC20(inflationaryCRC).approve(address(circlesLBPFactory), 48 ether);
        // try to mint before lbp
        vm.expectRevert();
        _groupMint(10 ether);
        // 3. create lbp
        vm.prank(testAccount);
        circlesLBPFactory.createLBP{value: 50 ether}(address(testGroupSafe), 0.01 ether, 7 days);
        // mint group token
        _groupMint(10 ether);
    }

    function _groupMint(uint256 amount) internal {
        address[] memory collateralAvatars = new address[](1);
        collateralAvatars[0] = testAccount;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.prank(testAccount);
        hub.groupMint(address(testGroupSafe), collateralAvatars, amounts, "");
    }

    function _executeSafeTx(Safe safe, address to, bytes memory data, Enum.Operation operation) internal {
        uint256 nonce = safe.nonce();
        bytes32 txHash = safe.getTransactionHash(
            to, // to
            0, // value
            data,
            operation,
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            address(0), // refundReceiver
            nonce // nonce
        );

        // Safe flow with approvedHash
        uint256 threshold = safe.getThreshold();
        address[] memory owners = safe.getOwners();
        bytes memory signatures;
        for (uint256 i; i < threshold;) {
            // use owner to send tx
            vm.prank(owners[i]);
            safe.approveHash(txHash);
            // craft signatures
            //                                                                      r               s           v
            bytes memory approvedHashSignature = abi.encodePacked(uint256(uint160(owners[i])), bytes32(0), bytes1(0x01));
            // TODO: need to sort owners first
            signatures = bytes.concat(signatures, approvedHashSignature);
            unchecked {
                ++i;
            }
        }

        bool success = safe.execTransaction(
            to, // to
            0, // value
            data,
            operation,
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            payable(address(0)), // refundReceiver
            signatures // signatures
        );
        assertTrue(success);
    }
}
