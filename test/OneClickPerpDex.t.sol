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

        usdc.mint(address(this), 100_000_000e6);
        usdc.approve(address(perpDex), type(uint256).max);
        perpDex.depositLP(100_000_000e6);

        usdc.mint(trader, MARGIN * 10);
        vm.startPrank(trader);
        perpDex.registerUsername("trader");
        usdc.approve(address(perpDex), type(uint256).max);
        perpDex.deposit(MARGIN * 10);
        vm.stopPrank();
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
        perpDex.modifyTpSl(trader, positions[0].id, 56_000e8, 0);
    }

    function testModifyZeroTPResetsToPairMaxTP() public {
        perpDex.updatePairMaxTP("BTC_USD", 2e18);
        _openLong(55_000e8);

        OneClickPerpDex.Position[] memory positions = perpDex
            .getUserPositions(trader);
        perpDex.modifyTpSl(trader, positions[0].id, 0, 0);

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

    function testPairMaxTPSetterRejectsUnusableValue() public {
        vm.expectRevert("maxTP too low for max leverage");
        perpDex.updatePairMaxTP("BTC_USD", 0.05e18);
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
