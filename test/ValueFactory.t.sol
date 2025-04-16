// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {CirclesBackingFactory} from "src/CirclesBackingFactory.sol";
import {ValueFactory} from "src/ValueFactory.sol";
import {IAggregatorV3Interface} from "src/interfaces/IAggregatorV3Interface.sol";
import {MockPriceFeed} from "test/mock/MockPriceFeed.sol";
import {BaseTestContract} from "test/helpers/BaseTestContract.sol";

/**
 * @title ValueFactoryTest
 * @notice Foundry test suite for ValueFactory instance.
 */
contract ValueFactoryTest is Test, BaseTestContract {

    // -------------------------------------------------------------------------
    // Admin-Only Tests
    // -------------------------------------------------------------------------

    function test_SetSlippageBPS() public {
        vm.prank(FACTORY_ADMIN);
        uint256 newBPSvalue = 5000;
        factory.setSlippageBPS(newBPSvalue);

        uint256 currentValue = ValueFactory(factory.valueFactory()).slippageBPS();
        assertEq(currentValue, newBPSvalue);
    }

    function test_SetSlippageOutOfBoundaries() public {
        uint256 initialValue = ValueFactory(factory.valueFactory()).slippageBPS();

        vm.prank(FACTORY_ADMIN);
        uint256 newBPSvalue = 15000;
        factory.setSlippageBPS(newBPSvalue);
        // @notice the function stays silent if BPS is not updated when trying to set slippage bps out of boundaries 

        uint256 currentValue = ValueFactory(factory.valueFactory()).slippageBPS();
        assertNotEq(newBPSvalue, currentValue);
        assertEq(initialValue, currentValue);
    }

    function test_SetTokenPriceFeed() public {
        vm.prank(FACTORY_ADMIN);
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));
    }

    function test_RevertIf_SlippageSetNotByFactory() public {
        ValueFactory oracleFactoryAddress = factory.valueFactory();
        vm.expectRevert(ValueFactory.OnlyBackingFactory.selector);
        ValueFactory(oracleFactoryAddress).setSlippageBPS(100);
    }


    function test_RevertIf_PriceFeedSetNotByAdmin() public {
        vm.expectRevert(CirclesBackingFactory.OnlyAdmin.selector);
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));
    }

    function test_RevertIf_PriceFeedSetNotByFactory() public {
        ValueFactory oracleFactoryAddress = factory.valueFactory();
        vm.expectRevert(ValueFactory.OnlyBackingFactory.selector);
        oracleFactoryAddress.setOracle(address(mockToken), address(mockTokenPriceFeed));
    }

    // -------------------------------------------------------------------------
    // Oracles settings
    // -------------------------------------------------------------------------

    function test_GetTokenPrices() public view {
        ValueFactory valueFactory = factory.valueFactory();
        uint256 priceUint256 = ValueFactory(valueFactory).getValue(USDC);
        bytes32 priceBytes32 = ValueFactory(valueFactory).getValue(abi.encode(USDC));
        assertEq(priceUint256, uint256(priceBytes32));
    }

    function test_GetTokenPricesForTokenWithFewDecimals() public {
        uint8 DECIMALS = 1;
        int256 TEST_PRICE = 10_000; // $1000.0 with 1 decimal
        mockTokenPriceFeed = new MockPriceFeed(DECIMALS, "MockTokenPrice", 1, TEST_PRICE);

        vm.prank(FACTORY_ADMIN);
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));
        ValueFactory valueFactory = factory.valueFactory();
        uint256 tokenAmount = valueFactory.getValue(address(mockToken));

        // Verify we get a positive amount with valid price
        assertGt(tokenAmount, 1, "Token amount should be positive with valid price");
    }

    function test_PriceUpdate() public {
        // Setup
        uint8 DECIMALS = 1;
        int256 INITIAL_PRICE = 10_000; // $1000.0 with 1 decimal
        mockTokenPriceFeed = new MockPriceFeed(DECIMALS, "MockTokenPrice", 1, INITIAL_PRICE);

        vm.prank(FACTORY_ADMIN);
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));
        ValueFactory valueFactory = factory.valueFactory();
        uint256 initialAmount = valueFactory.getValue(address(mockToken));

        // Test price update - higher price should result in lower token amount
        int256 DOUBLED_PRICE = 20_000; // $2000.0 with 1 decimal
        mockTokenPriceFeed.updateAnswer(DOUBLED_PRICE);
        uint256 newAmount = valueFactory.getValue(address(mockToken));

        assertLt(newAmount, initialAmount, "Higher price should result in lower token amount");
        // It should be roughly half the amount since we doubled the price
        assertApproxEqRel(newAmount, initialAmount / 2, 0.01e18, "Amount should be approximately halved");
    }

    function test_StalePriceDataHandling() public {
        // Setup
        uint8 DECIMALS = 1;
        int256 TEST_PRICE = 10_000;
        mockTokenPriceFeed = new MockPriceFeed(DECIMALS, "MockTokenPrice", 1, TEST_PRICE);

        vm.prank(FACTORY_ADMIN);
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));
        ValueFactory valueFactory = factory.valueFactory();

        mockTokenPriceFeed.updateAnswer(TEST_PRICE);
        // Test with stale price data (more than 1 day old)
        uint256 staleTimestamp = block.timestamp + 2 days;
        vm.warp(staleTimestamp);

        uint256 staleAmount = valueFactory.getValue(address(mockToken));
        assertEq(staleAmount, 1, "Stale price data should return minimal amount of 1");
    }

    function test_ZeroPriceHandling() public {
        // Setup
        uint8 DECIMALS = 1;
        int256 TEST_PRICE = 10_000;
        mockTokenPriceFeed = new MockPriceFeed(DECIMALS, "MockTokenPrice", 1, TEST_PRICE);

        vm.prank(FACTORY_ADMIN);
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));
        ValueFactory valueFactory = factory.valueFactory();

        // First check with valid price
        uint256 validAmount = valueFactory.getValue(address(mockToken));
        assertGt(validAmount, 1, "Valid price should return more than minimal amount");

        // Test with zero price
        mockTokenPriceFeed.updateAnswer(0);
        uint256 zeroAmount = valueFactory.getValue(address(mockToken));
        assertEq(zeroAmount, 1, "Zero price should return minimal amount of 1");
    }

    function testFuzz_SlippageImpactAcrossDecimalRanges(uint8 fuzzedDecimals) public {
        // Constrain decimals to a realistic range (1-20)
        uint8 oracleDecimals = uint8(bound(fuzzedDecimals, 1, 20));

        // Setup with a token that has few decimals
        int256 TEST_PRICE = 1_000 * int256(10 ** oracleDecimals);
        mockTokenPriceFeed = new MockPriceFeed(oracleDecimals, "MockTokenPrice", 1, TEST_PRICE);

        // Constants from the ValueFactory contract
        uint256 MAX_BPS = 10000; // 100% in basis points (from ValueFactory contract)
        uint256 DEFAULT_SLIPPAGE_BPS = 500; // Default 5% slippage

        vm.prank(FACTORY_ADMIN);
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));
        ValueFactory valueFactory = factory.valueFactory();

        // Verify the default slippage matches what we expect
        assertEq(valueFactory.slippageBPS(), DEFAULT_SLIPPAGE_BPS, "Initial slippage should be 500 BPS (5%)");

        // Get token amount with default slippage
        uint256 defaultSlippageAmount = valueFactory.getValue(address(mockToken));

        // Change slippage to 10%
        uint256 NEW_SLIPPAGE_BPS = 1000; // 10% slippage
        vm.prank(FACTORY_ADMIN);
        factory.setSlippageBPS(NEW_SLIPPAGE_BPS);

        // Verify slippage was updated correctly
        assertEq(valueFactory.slippageBPS(), NEW_SLIPPAGE_BPS, "Slippage should be updated to 1000 BPS (10%)");

        // Get token amount with increased slippage
        uint256 higherSlippageAmount = valueFactory.getValue(address(mockToken));

        // Basic check: higher slippage should result in lower token amount
        assertLt(higherSlippageAmount, defaultSlippageAmount, "Higher slippage should result in lower buy amount");

        // Calculate the expected ratio between amounts with different slippages
        // From the ValueFactory contract:
        //   buyAmount = (buyAmount * (MAX_BPS - slippageBPS)) / MAX_BPS;
        //
        // With default 5% slippage: effective multiplier = (10000 - 500)/10000 = 0.95
        // With new 10% slippage: effective multiplier = (10000 - 1000)/10000 = 0.90
        //
        // Expected ratio = 0.90 / 0.95 = 0.947... (approximately 94.7%)
        // In basis points: (9000 * 10000) / 9500 = 9474 BPS
        uint256 expectedRatio = (MAX_BPS - NEW_SLIPPAGE_BPS) * MAX_BPS / (MAX_BPS - DEFAULT_SLIPPAGE_BPS);
        uint256 actualRatio = higherSlippageAmount * MAX_BPS / defaultSlippageAmount;
        
        // Check that the ratio is as expected (with a small tolerance for rounding errors)
        assertEq(actualRatio, expectedRatio, "Slippage impact should match the expected ratio");
    }

    // @notice division by zero error
    function test_RevertIf_PriceIsVeryLow() public {
        // Setup a token with high decimals (greater than 8)
        uint8 ORACLE_DECIMALS = 9;

        // Create a price feed with an extremely low price - just 1 unit
        // This is equivalent to $0.00000001 for an 8-decimal oracle
        int256 EXTREMELY_LOW_PRICE = 1;

        mockTokenPriceFeed = new MockPriceFeed(ORACLE_DECIMALS, "LowPriceFeed", 1, EXTREMELY_LOW_PRICE);

        // Set the oracle
        vm.startPrank(FACTORY_ADMIN);
        // Then set our test token's oracle
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));

        ValueFactory valueFactory = factory.valueFactory();

        // Issue: When a token has an extremely low price and high decimals, the `_scalePrice`
        // function can scale the price down to zero due to integer division in Solidity.
        //
        // Since the contract only checks for zero prices BEFORE scaling (not after), this creates
        // a division by zero error in the calculation:
        // `buyAmount = (buyUnit * basePrice * SELL_AMOUNT) / (quotePrice * SELL_UNIT)`

        // Specifically:
        // 1. A token with 9 decimals having a price of 1 (0.000000001)
        // 2. When scaled from 9 to 8 decimals: 1 / 10 = 0 (in integer math)
        // 3. This leads to division by zero when calculating the buy amount

        // Proposed fix: Add a safety check for zero AFTER scaling the prices:
        //  - After `quotePrice = _scalePrice(quotePrice, buyOracle.feedDecimals, 8);`
        //  - Add: `if (quotePrice == 0) { buyAmount = 1; } else { ... }`

        // Check if the function reverts due to division by zero
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x12));
        uint256 amount = valueFactory.getValue(address(mockToken));

        // @todo uncomment after the fix
        // assertEq(amount, 1, "Low price should return minimal amount of 1");
    }

    function test_RemovePriceFeed() public {
        ValueFactory valueFactory = factory.valueFactory();

        vm.prank(FACTORY_ADMIN);
        factory.setOracle(address(mockToken), address(mockTokenPriceFeed));

        (IAggregatorV3Interface priceFeedAddress, uint8 feedDecimals, uint8 tokenDecimals) =
            valueFactory.oracles(address(mockToken));
        // Price feed was added correctly
        assertEq(address(priceFeedAddress), address(mockTokenPriceFeed));
        assertEq(feedDecimals, mockTokenPriceFeed.decimals());
        assertEq(tokenDecimals, mockToken.decimals());

        vm.prank(FACTORY_ADMIN);
        factory.setOracle(address(mockToken), address(0));
        (priceFeedAddress, feedDecimals, tokenDecimals) = valueFactory.oracles(address(mockToken));
        assertEq(address(priceFeedAddress), address(0));
        assertEq(feedDecimals, 0);
        assertEq(tokenDecimals, 0);
    }
}