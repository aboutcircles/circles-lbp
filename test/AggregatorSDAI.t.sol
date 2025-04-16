// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "src/adapters/AggregatorSDAI.sol";
import {IAggregatorV3Interface} from "src/interfaces/IAggregatorV3Interface.sol";

contract AggregatorSDAITest is Test {
    uint256 public gnosisFork;
    AggregatorSDAI public aggregatorSDAI;
    IAggregatorV3Interface public daiFeed;
    ISDAI public sdai;

    function setUp() public {
        // Fork from Gnosis
        gnosisFork = vm.createFork(vm.envString("GNOSIS_RPC"));
        vm.selectFork(gnosisFork);

        // Deploy the adapter
        aggregatorSDAI = new AggregatorSDAI();

        // Reference the existing contracts
        daiFeed = IAggregatorV3Interface(address(0x678df3415fc31947dA4324eC63212874be5a82f8));
        sdai = ISDAI(address(0xaf204776c7245bF4147c2612BF6e5972Ee483701));
    }

    // Test basic functions
    function test_GetDecimals() public view {
        assertEq(aggregatorSDAI.decimals(), 8);
    }

    function test_GetDescription() public view {
        assertEq(aggregatorSDAI.description(), "SDAI/USD");
    }

    function test_GetVersion() public view {
        assertEq(aggregatorSDAI.version(), 4);
    }

    // Test getRoundData with mocked values
    function test_MockedGetRoundData() public {
        // Mock a specific round ID and price
        uint80 mockedRoundId = 100;
        int256 mockedDaiPrice = 2 * 10 ** 8; // $2.00

        // Calculate what the SDAI price should be based on the current exchange rate
        uint256 shares = sdai.convertToShares(1 ether);
        int256 expectedSdaiPrice = int256(uint256(mockedDaiPrice) * 1 ether / shares);

        // Mock the getRoundData call to the DAI feed
        vm.mockCall(
            address(daiFeed),
            abi.encodeWithSelector(IAggregatorV3Interface.getRoundData.selector, mockedRoundId),
            abi.encode(mockedRoundId, mockedDaiPrice, uint256(1), block.timestamp, mockedRoundId)
        );

        // Call the adapter's getRoundData
        (uint80 returnedRoundId, int256 sdaiPrice,,, uint80 returnedAnsweredInRound) =
            aggregatorSDAI.getRoundData(mockedRoundId);

        // Assert that the SDAI price matches our expected calculation
        assertEq(returnedRoundId, mockedRoundId);
        assertEq(sdaiPrice, expectedSdaiPrice);
        assertEq(returnedAnsweredInRound, mockedRoundId);
    }

    // Test edge case: Zero shares (should revert)
    function test_RevertIf_ZeroShares() public {
        // Mock SDAI.convertToShares to return 0
        vm.mockCall(address(sdai), abi.encodeWithSelector(ISDAI.convertToShares.selector, 1 ether), abi.encode(0));

        // This should revert due to division by zero
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x12));
        aggregatorSDAI.latestRoundData();
    }

    // Test fuzz: Test with random DAI prices
    function testFuzz_DaiPrices(uint256 daiPrice) public {
        // Bound the price to reasonable values to prevent overflow
        vm.assume(daiPrice > 0 && daiPrice < 1000000 * 10 ** 8); // Between $0 and $1M

        // Convert to int256
        int256 daiPriceInt = int256(daiPrice);

        // Mock the DAI price
        vm.mockCall(
            address(daiFeed),
            abi.encodeWithSelector(IAggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), daiPriceInt, uint256(1), block.timestamp, uint80(1))
        );

        // Get the current SDAI to DAI exchange rate
        uint256 shares = sdai.convertToShares(1 ether);

        // Calculate expected SDAI price
        int256 expectedSdaiPrice = int256(daiPrice * 1 ether / shares);

        // Get actual SDAI price
        (, int256 actualSdaiPrice,,,) = aggregatorSDAI.latestRoundData();

        // Verify
        assertEq(actualSdaiPrice, expectedSdaiPrice);
    }
}
