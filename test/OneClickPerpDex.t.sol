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
        assertEq(positions[0].payout, 198e6);
        assertEq(perpDex.userBalances(trader), (MARGIN * 10) + 98e6);
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
