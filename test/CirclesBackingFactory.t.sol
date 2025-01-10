// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CirclesBackingFactory} from "src/factory/CirclesBackingFactory.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {INoProtocolFeeLiquidityBootstrappingPoolFactory} from "src/interfaces/ILBPFactory.sol";
import {ILBP} from "src/interfaces/ILBP.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

contract MockToken is ERC20 {
    /**
     * @notice Constructor - solmate ERC20 token.
     * @param _name Token name.
     * @param _symbol Token symbol.
     * @param _totalSupply Token total supply.
     */
    constructor(string memory _name, string memory _symbol, uint256 _totalSupply)
        payable
        ERC20(_name, _symbol, uint8(18))
    {
        _mint(msg.sender, _totalSupply);
    }
}

contract MockJoin {
    /// @notice Balancer v2 Vault.
    address public constant VAULT = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    /// @notice Balancer v2 LBPFactory.
    INoProtocolFeeLiquidityBootstrappingPoolFactory public constant LBP_FACTORY =
        INoProtocolFeeLiquidityBootstrappingPoolFactory(address(0x85a80afee867aDf27B50BdB7b76DA70f1E853062));
    /// @dev LBP token weight 1%.
    uint256 internal constant WEIGHT_1 = 0.01 ether;
    /// @dev LBP token weight 99%.
    uint256 internal constant WEIGHT_99 = 0.99 ether;
    /// @dev Swap fee percentage is set to 1%.
    uint256 internal constant SWAP_FEE = 0.01 ether;
    /// @notice Amount of InflationaryCircles to use in LBP initial liquidity.
    uint256 public constant CRC_AMOUNT = 48 ether;

    /// @notice Emitted when a LBP is created.
    event LBPCreated(address indexed circlesBackingInstance, address indexed lbp);

    /// @notice Creates LBP with underlying assets: `backingAssetAmount` backingAsset(`backingAsset`) and `CRC_AMOUNT` InflationaryCircles(`personalCRC`).
    /// @param personalCRC .
    function createLBP(address personalCRC, address backingAsset, uint256 backingAssetAmount)
        external
        returns (address lbp)
    {
        // prepare inputs
        IERC20[] memory tokens = new IERC20[](2);
        bool tokenZero = personalCRC < backingAsset;
        tokens[0] = tokenZero ? IERC20(personalCRC) : IERC20(backingAsset);
        tokens[1] = tokenZero ? IERC20(backingAsset) : IERC20(personalCRC);

        uint256[] memory weights = new uint256[](2);
        weights[0] = tokenZero ? WEIGHT_1 : WEIGHT_99;
        weights[1] = tokenZero ? WEIGHT_99 : WEIGHT_1;

        // create LBP
        lbp = LBP_FACTORY.create(
            "sdf_name",
            "sdf_symbol",
            tokens,
            weights,
            SWAP_FEE,
            msg.sender, // lbp owner
            true // enable swap on start
        );

        emit LBPCreated(msg.sender, lbp);

        bytes32 poolId = ILBP(lbp).getPoolId();

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = tokenZero ? CRC_AMOUNT : backingAssetAmount;
        amountsIn[1] = tokenZero ? backingAssetAmount : CRC_AMOUNT;

        bytes memory userData = abi.encode(ILBP.JoinKind.INIT, amountsIn);
        // CHECK: only owner can join pool, however it looks like anyone can do this call setting owner address as sender
        // provide liquidity into lbp
        IVault(VAULT).joinPool(
            poolId,
            msg.sender, // sender
            msg.sender, // recipient
            IVault.JoinPoolRequest(tokens, amountsIn, userData, false)
        );
    }
}

contract CirclesBackingFactoryTest is Test {
    CirclesBackingFactory public factory;
    address factoryAdmin = address(0x4583759874359754305480345);
    MockJoin public mockJoin;
    address testAccount = address(0x458437598234234234);
    address personalCRC;
    address backingAsset;
    address VAULT;
    uint256 backingAssetAmount = 100e6;

    uint256 blockNumber = 37968717;
    uint256 gnosis;

    function setUp() public {
        gnosis = vm.createFork(vm.envString("GNOSIS_RPC"), blockNumber);
        vm.selectFork(gnosis);
        factory = new CirclesBackingFactory(factoryAdmin);
        mockJoin = new MockJoin();
        personalCRC = address(new MockToken("crc", "crc", 10_000 ether));
        IERC20(personalCRC).transfer(testAccount, 10_000 ether);
        backingAsset = address(0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0); // usdc
        deal(backingAsset, testAccount, 1000e6);
        VAULT = mockJoin.VAULT();
    }

    function test_Join() public {
        vm.prank(testAccount);
        IERC20(personalCRC).approve(VAULT, 48 ether);
        vm.prank(testAccount);
        IERC20(backingAsset).approve(VAULT, backingAssetAmount);

        mockJoin.createLBP(personalCRC, backingAsset, backingAssetAmount);
    }
}
