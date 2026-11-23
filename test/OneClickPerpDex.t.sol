// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {OneClickPerpDex} from "../src/OneClickPerpDex.sol";
import {ocUSDC} from "../src/ocUSDC.sol";

contract OneClickPerpDexMaxTPTest is Test {
    uint256 internal constant ENTRY_PRICE = 50_000e8;
    uint256 internal constant MARGIN = 100e6;
    uint256 internal constant LEVERAGE = 10;

    address internal trader = makeAddr("trader");

    MockUSDC internal usdc;
    ocUSDC internal lpToken;
    OneClickPerpDex internal perpDex;

    function setUp() public {
        usdc = new MockUSDC();
        lpToken = new ocUSDC();
        perpDex = new OneClickPerpDex(address(usdc), address(lpToken));

        perpDex.addPair("BTC_USD", 2000, 50_000e6, 2, 100, 5e18);
        lpToken.setOneClickPerpDex(address(perpDex));
        perpDex.authorizeBackend(address(this), true);

        usdc.ownerMint(address(this), 100_000_000e6);
        usdc.approve(address(perpDex), type(uint256).max);
        perpDex.depositLP(100_000_000e6);

        usdc.ownerMint(trader, MARGIN * 10);
        vm.startPrank(trader);
        perpDex.registerUsername("trader");
        usdc.approve(address(perpDex), type(uint256).max);
        perpDex.deposit(MARGIN * 10);
        vm.stopPrank();
    }

    function testOpenAtPairMaxLeverageAbove100() public {
        perpDex.updatePairConfig("BTC_USD", 2000, 50_000e6, 2, 500);

        perpDex.openPosition(trader, "BTC_USD", true, MARGIN, 500, ENTRY_PRICE, 0, 0);

        OneClickPerpDex.Position[] memory positions = perpDex.getUserPositions(trader);
        assertEq(positions[0].leverage, 500);
        assertEq(positions[0].size, MARGIN * 500);
    }

    function testOpenRejectsLeverageAbovePairMaximum() public {
        perpDex.updatePairConfig("BTC_USD", 2000, 50_000e6, 2, 250);

        vm.expectRevert(OneClickPerpDex.InvalidLeverage.selector);
        perpDex.openPosition(trader, "BTC_USD", true, MARGIN, 251, ENTRY_PRICE, 0, 0);
    }

    function testOpenRejectsLeverageBelowPairMinimum() public {
        vm.expectRevert(OneClickPerpDex.InvalidLeverage.selector);
        perpDex.openPosition(trader, "BTC_USD", true, MARGIN, 1, ENTRY_PRICE, 0, 0);
    }

    function testOpenWithoutTPDefaultsToPairMaxTP() public {
        perpDex.updatePairMaxTP("BTC_USD", 2e18);

        _openLong(0);

        OneClickPerpDex.Position[] memory positions = perpDex
            .getUserPositions(trader);
        assertEq(positions[0].takeProfit, 60_000e8);
    }

    function testConstructorDoesNotAddPairs() public {
        OneClickPerpDex emptyDex = new OneClickPerpDex(
            address(usdc),
            address(lpToken)
        );
        assertEq(emptyDex.getAllPairs().length, 0);
    }

    function testInitialLpDepositMintsSameDisplayedTokenAmount() public {
        assertEq(lpToken.decimals(), 6);
        assertEq(lpToken.balanceOf(address(this)), 100_000_000e6);
        assertEq(perpDex.getocUSDCPrice(), 1e18);
    }

    function testUserLPStakingValueUsesOcUSDCShareOfLPStaking() public {
        address secondLP = makeAddr("secondLP");
        uint256 secondLPDeposit = 50_000_000e6;
        usdc.ownerMint(secondLP, secondLPDeposit);

        vm.startPrank(secondLP);
        usdc.approve(address(perpDex), secondLPDeposit);
        perpDex.depositLP(secondLPDeposit);
        vm.stopPrank();

        assertEq(perpDex.getPoolValue(), 150_000_000e6);
        assertEq(perpDex.getUserLPStakingValue(address(this)), 100_000_000e6);
        assertEq(perpDex.getUserLPStakingValue(secondLP), secondLPDeposit);
        assertEq(perpDex.getUserLPStakingValue(trader), 0);
    }

    function testOpenRejectsTPAbovePairMaxTP() public {
        perpDex.updatePairMaxTP("BTC_USD", 1e18);

        vm.expectRevert("TP exceeds pair maxTP");
        _openLong(56_000e8);
    }

    function testShortDefaultAndMaxTPValidation() public {
        perpDex.updatePairMaxTP("BTC_USD", 1e18);

        _openShort(0);
        OneClickPerpDex.Position[] memory positions = perpDex
            .getUserPositions(trader);
        assertEq(positions[0].takeProfit, 45_000e8);

        vm.expectRevert("TP exceeds pair maxTP");
        _openShort(44_000e8);
    }

    function testModifyRejectsTPAbovePairMaxTP() public {
        perpDex.updatePairMaxTP("BTC_USD", 1e18);
        _openLong(0);

        OneClickPerpDex.Position[] memory positions = perpDex
            .getUserPositions(trader);

        vm.expectRevert("TP exceeds pair maxTP");
        perpDex.modifyTpSl(trader, positions[0].id, 56_000e8, 0, ENTRY_PRICE);
    }

    function testModifyZeroTPResetsToPairMaxTP() public {
        perpDex.updatePairMaxTP("BTC_USD", 2e18);
        _openLong(55_000e8);

        OneClickPerpDex.Position[] memory positions = perpDex
            .getUserPositions(trader);
        perpDex.modifyTpSl(trader, positions[0].id, 0, 0, ENTRY_PRICE);

        positions = perpDex.getUserPositions(trader);
        assertEq(positions[0].takeProfit, 60_000e8);
    }

    function testCloseCapsProfitAtPairMaxTP() public {
        perpDex.updatePairMaxTP("BTC_USD", 1e18);
        _openLong(0);

        OneClickPerpDex.Position[] memory positions = perpDex
            .getUserPositions(trader);
        perpDex.closePosition(trader, positions[0].id, 100_000e8);

        positions = perpDex.getUserPositions(trader);
        assertEq(positions[0].payout, 196_500_000);
        assertEq(perpDex.userBalances(trader), (MARGIN * 10) + 96_500_000);
        assertEq(perpDex.secondaryVaultBalance(), 1_500_000);
        assertEq(perpDex.getPoolValue(), 100_000_000e6 - 98e6);
        assertEq(perpDex.vaultTotalPnL(), -98e6);
        assertEq(perpDex.vaultTotalLoss(), 98e6);
    }

    function testFuzzProfitFeeSplitConservesFunds(bool isLong, uint64 priceMoveSeed) public {
        uint256 priceMove = bound(uint256(priceMoveSeed), 1, ENTRY_PRICE / 2);
        perpDex.openPosition(trader, "BTC_USD", isLong, MARGIN, LEVERAGE, ENTRY_PRICE, 0, 0);
        OneClickPerpDex.Position[] memory positions = perpDex.getUserPositions(trader);
        perpDex.closePosition(trader, positions[0].id, isLong ? ENTRY_PRICE + priceMove : ENTRY_PRICE - priceMove);

        uint256 profit = (MARGIN * LEVERAGE * priceMove) / ENTRY_PRICE;
        uint256 totalFee = (profit * 350) / 10_000;
        uint256 platformFee = (profit * 150) / 10_000;
        uint256 liquidityFee = totalFee - platformFee;
        positions = perpDex.getUserPositions(trader);
        assertEq(positions[0].payout, MARGIN + profit - totalFee);
        assertEq(perpDex.userBalances(trader), MARGIN * 10 + profit - totalFee);
        assertEq(perpDex.secondaryVaultBalance(), platformFee);
        assertEq(perpDex.getPoolValue(), 100_000_000e6 - profit + liquidityFee);
        assertEq(perpDex.vaultTotalPnL(), int256(liquidityFee) - int256(profit));
        assertEq(
            perpDex.getPoolValue() + platformFee + perpDex.totalUserBalances(),
            usdc.balanceOf(address(perpDex))
        );
    }

    function testFuzzLossAndBreakEvenHaveNoFee(bool isLong, bool breakEven) public {
        perpDex.openPosition(trader, "BTC_USD", isLong, MARGIN, LEVERAGE, ENTRY_PRICE, 0, 0);
        OneClickPerpDex.Position[] memory positions = perpDex.getUserPositions(trader);
        uint256 priceMove = breakEven ? 0 : ENTRY_PRICE / 100;
        perpDex.closePosition(trader, positions[0].id, isLong ? ENTRY_PRICE - priceMove : ENTRY_PRICE + priceMove);

        uint256 loss = breakEven ? 0 : 10e6;
        positions = perpDex.getUserPositions(trader);
        assertEq(positions[0].payout, MARGIN - loss);
        assertEq(perpDex.userBalances(trader), MARGIN * 10 - loss);
        assertEq(perpDex.secondaryVaultBalance(), 0);
        assertEq(perpDex.getPoolValue(), 100_000_000e6 + loss);
        assertEq(perpDex.vaultTotalPnL(), int256(loss));
    }

    function testPlatformVaultWithdrawalDoesNotSpendLpCapital() public {
        usdc.ownerMint(address(this), 10e6);
        perpDex.depositSecondaryVault(10e6);
        assertEq(perpDex.getPoolValue(), 100_000_000e6);

        perpDex.updatePairMaxTP("BTC_USD", 1e18);
        _openLong(0);
        OneClickPerpDex.Position[] memory positions = perpDex.getUserPositions(trader);
        perpDex.closePosition(trader, positions[0].id, 60_000e8);

        assertEq(perpDex.secondaryVaultBalance(), 11_500_000);
        perpDex.withdrawSecondaryVault(10e6);
        assertEq(perpDex.secondaryVaultBalance(), 0);
        assertEq(usdc.balanceOf(address(this)), 11_500_000);
        assertEq(perpDex.getPoolValue(), 100_000_000e6 - 98e6);
    }

    function testFuzzPairMaxTPAllowsCloseDefaultAtMaxLeverage(bool isLong) public {
        perpDex.addPair("ETH_USD", 100, 50_000e6, 2, 100, 0.05e18);
        perpDex.updatePairMaxTP("BTC_USD", 0.05e18);
        perpDex.updatePairConfig("BTC_USD", 2000, 50_000e6, 2, 200);

        perpDex.openPosition(trader, "BTC_USD", isLong, MARGIN, 200, ENTRY_PRICE, 0, 0);

        OneClickPerpDex.Position[] memory positions = perpDex.getUserPositions(trader);
        uint256 priceDelta = (ENTRY_PRICE * 0.05e18) / (1e18 * 200);
        assertLt(priceDelta, ENTRY_PRICE / 1000);
        assertEq(positions[0].takeProfit, isLong ? ENTRY_PRICE + priceDelta : ENTRY_PRICE - priceDelta);
    }

    function testPairMaxTPSetterStillRejectsZero() public {
        vm.expectRevert("Invalid maxTP");
        perpDex.updatePairMaxTP("BTC_USD", 0);
    }

    function testFuzzOpenAndTriggerCloseTpSl(bool isLong, bool hitTP, uint64 distanceSeed) public {
        uint256 distance = bound(uint256(distanceSeed), 1, ENTRY_PRICE / 1000 - 1);
        uint256 tp = isLong ? ENTRY_PRICE + distance : ENTRY_PRICE - distance;
        uint256 sl = isLong ? ENTRY_PRICE - distance : ENTRY_PRICE + distance;

        perpDex.openPosition(trader, "BTC_USD", isLong, MARGIN, LEVERAGE, ENTRY_PRICE, tp, sl);

        OneClickPerpDex.Position[] memory positions = perpDex.getUserPositions(trader);
        assertFalse(positions[0].isClosed);
        assertEq(positions[0].takeProfit, tp);
        assertEq(positions[0].stopLoss, sl);

        vm.expectRevert("No TP/SL triggered");
        perpDex.triggerTpSl(trader, positions[0].id, ENTRY_PRICE);

        uint256 triggerPrice = hitTP ? tp : sl;
        perpDex.triggerTpSl(trader, positions[0].id, triggerPrice);

        positions = perpDex.getUserPositions(trader);
        assertTrue(positions[0].isClosed);
        assertEq(positions[0].closePrice, triggerPrice);
    }

    function testFuzzModifyAndTriggerCloseTpSl(
        bool isLong, bool hitTP, bool priceMoved, uint64 distanceSeed
    ) public {
        if (isLong) _openLong(0);
        else _openShort(0);
        OneClickPerpDex.Position[] memory positions = perpDex.getUserPositions(trader);

        uint256 currentPrice = priceMoved
            ? (isLong ? ENTRY_PRICE + 1_000e8 : ENTRY_PRICE - 1_000e8)
            : ENTRY_PRICE;
        uint256 distance = bound(uint256(distanceSeed), 1, currentPrice / 1000 - 1);
        uint256 tp = isLong ? currentPrice + distance : currentPrice - distance;
        uint256 sl = isLong ? currentPrice - distance : currentPrice + distance;
        perpDex.modifyTpSl(trader, positions[0].id, tp, sl, currentPrice);

        positions = perpDex.getUserPositions(trader);
        assertFalse(positions[0].isClosed);
        assertEq(positions[0].takeProfit, tp);
        assertEq(positions[0].stopLoss, sl);

        uint256 triggerPrice = hitTP ? tp : sl;
        perpDex.triggerTpSl(trader, positions[0].id, triggerPrice);

        positions = perpDex.getUserPositions(trader);
        assertTrue(positions[0].isClosed);
        assertEq(positions[0].closePrice, triggerPrice);
    }

    function testFuzzWorstCaseProfitCapLimitsExposureToFullPool(bool isLong) public {
        ocUSDC limitedLp = new ocUSDC();
        OneClickPerpDex limitedDex = new OneClickPerpDex(address(usdc), address(limitedLp));
        limitedDex.addPair("BTC_USD", 2000, 50_000e6, 2, 500, 5e18);
        limitedLp.setOneClickPerpDex(address(limitedDex));
        limitedDex.authorizeBackend(address(this), true);

        usdc.ownerMint(address(this), 1_000e6);
        usdc.approve(address(limitedDex), 1_000e6);
        limitedDex.depositLP(1_000e6);
        usdc.ownerMint(trader, 1_000e6);
        vm.startPrank(trader);
        usdc.approve(address(limitedDex), 1_000e6);
        limitedDex.deposit(1_000e6);
        vm.stopPrank();

        // Trader deposits and locked margins do not increase the LP risk budget.
        limitedDex.openPosition(trader, "BTC_USD", isLong, 100e6, 500, ENTRY_PRICE, 0, 0);
        vm.expectRevert(bytes(isLong ? "Insufficient long liquidity" : "Insufficient short liquidity"));
        limitedDex.openPosition(trader, "BTC_USD", isLong, 1e6, 2, ENTRY_PRICE, 0, 0);
        vm.roll(block.number + 1);
        limitedDex.openPosition(trader, "BTC_USD", !isLong, 100e6, 2, ENTRY_PRICE, 0, 0);

        assertEq(limitedDex.totalWorstCaseProfit(), 1_000e6);
        assertEq(limitedDex.getMaxWorstCaseProfit(), 1_000e6);
        assertEq(limitedDex.getPoolValue(), 1_000e6);
        assertEq(limitedDex.getDrawdownThreshold(), 700e6);

        vm.expectRevert("Exceeds 100% worst-case loss limit");
        limitedDex.openPosition(trader, "BTC_USD", true, 1e6, 2, ENTRY_PRICE, 0, 0);
        assertEq(limitedDex.totalWorstCaseProfit(), 1_000e6);

        limitedDex.updatePairMaxTP("BTC_USD", 1e18);
        (,uint256 cap, uint256 longMargin, uint256 shortMargin, uint256 availableLong, uint256 availableShort,,) =
            limitedDex.getAvailableLiquidity("BTC_USD");
        assertEq(cap, 500e6);
        assertEq(longMargin, 100e6);
        assertEq(shortMargin, 100e6);
        assertEq(availableLong, 0);
        assertEq(availableShort, 0);
        assertEq(limitedDex.pairInfo("BTC_USD").availableLiquidity, 0);
        assertEq(limitedDex.pairInfo("BTC_USD").usedLiquidity, 200e6);
    }

    function testFuzzNotionalOIAndMarginLiquidityReleasedOnCloseAndLiquidation(bool isLong, bool shouldLiquidate) public {
        perpDex.updatePairConfig("BTC_USD", 2000, 50_000e6, 2, 500);
        perpDex.openPosition(trader, "BTC_USD", isLong, 50e6, 500, ENTRY_PRICE, 0, 0);
        vm.roll(block.number + 1);
        perpDex.openPosition(trader, "BTC_USD", isLong, 50e6, 2, ENTRY_PRICE, 0, 0);

        (uint256 allocated, uint256 cap, uint256 longMargin, uint256 shortMargin, uint256 availableLong, uint256 availableShort,,) =
            perpDex.getAvailableLiquidity("BTC_USD");
        assertEq(allocated, 100_000_000e6);
        assertEq(cap, 10_000_000e6);
        assertEq(isLong ? longMargin : shortMargin, 100e6);
        assertEq(isLong ? availableLong : availableShort, cap - 100e6);
        assertEq(isLong ? availableShort : availableLong, cap);
        assertEq(perpDex.totalWorstCaseProfit(), 500e6);
        assertEq(perpDex.pairInfo("BTC_USD").availableLiquidity, cap * 2 - 100e6);
        assertEq(perpDex.pairInfo("BTC_USD").usedLiquidity, 100e6);
        assertEq(perpDex.getAllPairs()[0].usedLiquidity, 100e6);

        (uint256 longOI, uint256 shortOI, uint256 totalOI) = perpDex.getOpenInterest("BTC_USD");
        assertEq(isLong ? longOI : shortOI, 25_100e6);
        assertEq(isLong ? shortOI : longOI, 0);
        assertEq(totalOI, 25_100e6);

        OneClickPerpDex.Position[] memory positions = perpDex.getUserPositions(trader);
        if (shouldLiquidate) {
            perpDex.liquidate(trader, positions[0].id, isLong ? 49_000e8 : 51_000e8);
        } else {
            perpDex.closePosition(trader, positions[0].id, ENTRY_PRICE);
        }

        (,, longMargin, shortMargin,,,,) = perpDex.getAvailableLiquidity("BTC_USD");
        assertEq(isLong ? longMargin : shortMargin, 50e6);
        assertEq(perpDex.pairInfo("BTC_USD").usedLiquidity, 50e6);
        assertEq(perpDex.totalWorstCaseProfit(), 250e6);
        (longOI, shortOI, totalOI) = perpDex.getOpenInterest("BTC_USD");
        assertEq(isLong ? longOI : shortOI, 100e6);
        assertEq(totalOI, 100e6);

        perpDex.closePosition(trader, positions[1].id, ENTRY_PRICE);
        (,, longMargin, shortMargin,,,,) = perpDex.getAvailableLiquidity("BTC_USD");
        assertEq(longMargin, 0);
        assertEq(shortMargin, 0);
        assertEq(perpDex.pairInfo("BTC_USD").usedLiquidity, 0);
        assertEq(perpDex.totalWorstCaseProfit(), 0);
        (longOI, shortOI, totalOI) = perpDex.getOpenInterest("BTC_USD");
        assertEq(longOI, 0);
        assertEq(shortOI, 0);
        assertEq(totalOI, 0);
    }

    function testAvailableLiquidityUsesPairWeightAndMaxTP() public {
        perpDex.addPair("ETH_USD", 2000, 50_000e6, 2, 500, 10e18);
        (uint256 btcAllocation, uint256 btcCap,,,,,,) = perpDex.getAvailableLiquidity("BTC_USD");
        (uint256 ethAllocation, uint256 ethCap,,,,,,) = perpDex.getAvailableLiquidity("ETH_USD");
        assertEq(btcAllocation, 50_000_000e6);
        assertEq(ethAllocation, 50_000_000e6);
        assertEq(btcCap, 5_000_000e6);
        assertEq(ethCap, 2_500_000e6);

        (,uint256 unknownCap,,, uint256 availableLong, uint256 availableShort,,) = perpDex.getAvailableLiquidity("UNKNOWN");
        assertEq(unknownCap, 0);
        assertEq(availableLong, 0);
        assertEq(availableShort, 0);
    }

    function testPairInfoLiquidityTracksDepositsRatiosAndMaxTP() public {
        perpDex.addPair("ETH_USD", 2000, 50_000e6, 2, 500, 10e18);
        assertEq(perpDex.pairInfo("BTC_USD").availableLiquidity, 10_000_000e6);
        assertEq(perpDex.pairInfo("ETH_USD").availableLiquidity, 5_000_000e6);

        perpDex.updatePairConfig("BTC_USD", 6000, 50_000e6, 2, 500);
        assertEq(perpDex.totalLiquidityRatio(), 8000);
        assertEq(perpDex.pairInfo("BTC_USD").liquidityRatio, 6000);
        assertEq(perpDex.pairInfo("BTC_USD").availableLiquidity, 15_000_000e6);
        assertEq(perpDex.pairInfo("ETH_USD").availableLiquidity, 2_500_000e6);

        perpDex.updatePairMaxTP("ETH_USD", 5e18);
        assertEq(perpDex.pairInfo("ETH_USD").availableLiquidity, 5_000_000e6);

        usdc.ownerMint(address(this), 1_000e6);
        perpDex.depositLP(1_000e6);
        OneClickPerpDex.PairInfo[] memory pairs = perpDex.getAllPairs();
        assertEq(pairs[0].liquidityRatio, 6000);
        assertEq(pairs[0].availableLiquidity, 15_000_150e6);
        assertEq(pairs[1].maxTP, 5e18);
        assertEq(pairs[1].availableLiquidity, 5_000_050e6);
        assertEq(perpDex.allPairs(0).availableLiquidity, pairs[0].availableLiquidity);
    }

    function testPoolValueExcludesTotalUserBalances() public {
        address unregisteredTrader = makeAddr("unregisteredTrader");
        uint256 traderDeposit = 1_000e6;
        usdc.ownerMint(unregisteredTrader, traderDeposit);

        vm.startPrank(unregisteredTrader);
        usdc.approve(address(perpDex), traderDeposit);
        perpDex.deposit(traderDeposit);
        vm.stopPrank();

        assertEq(perpDex.getPoolValue(), 100_000_000e6);
        assertEq(
            perpDex.getPoolValue(),
            usdc.balanceOf(address(perpDex)) - perpDex.totalUserBalances()
        );
        assertEq(perpDex.getUserLPStakingValue(address(this)), 100_000_000e6);

        _openLong(0);
        assertEq(perpDex.getPoolValue(), 100_000_000e6);

        OneClickPerpDex.Position[] memory positions = perpDex.getUserPositions(trader);
        perpDex.closePosition(trader, positions[0].id, 49_500e8);

        // A trader loss reduces the user-fund liability and increases the
        // value available to LPs.
        assertEq(perpDex.getPoolValue(), 100_000_010e6);
        assertEq(
            perpDex.getPoolValue(),
            usdc.balanceOf(address(perpDex)) - perpDex.totalUserBalances()
        );
        assertEq(perpDex.totalStakedUSDC(), 100_000_000e6);
    }

    function testEmergencyCloseSupportsAnyConfiguredPair() public {
        perpDex.addPair("DOGE_USD", 100, 50_000e6, 2, 100, 5e18);
        perpDex.openPosition(
            trader,
            "DOGE_USD",
            true,
            MARGIN,
            LEVERAGE,
            10e8,
            0,
            0
        );

        string[] memory pairs = new string[](1);
        pairs[0] = "DOGE_USD";
        uint256[] memory prices = new uint256[](1);
        prices[0] = 11e8;

        perpDex.closeAllPositions(pairs, prices);

        OneClickPerpDex.Position[] memory positions = perpDex.getUserPositions(trader);
        assertTrue(positions[0].isClosed);
        assertEq(positions[0].closePrice, 11e8);
    }

    function testEmergencyCloseRejectsMismatchedPrices() public {
        string[] memory pairs = new string[](1);
        pairs[0] = "BTC_USD";
        uint256[] memory prices = new uint256[](0);

        vm.expectRevert("Pairs/prices length mismatch");
        perpDex.closeAllPositions(pairs, prices);
    }

    function _openLong(uint256 takeProfit) internal {
        perpDex.openPosition(
            trader,
            "BTC_USD",
            true,
            MARGIN,
            LEVERAGE,
            ENTRY_PRICE,
            takeProfit,
            0
        );
    }

    function _openShort(uint256 takeProfit) internal {
        perpDex.openPosition(
            trader,
            "BTC_USD",
            false,
            MARGIN,
            LEVERAGE,
            ENTRY_PRICE,
            takeProfit,
            0
        );
    }
}
