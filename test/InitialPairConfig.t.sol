// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {InitialPairConfig} from "../script/InitialPairConfig.sol";
import {PerpDex} from "../src/PerpDex.sol";
import {OneClickPerpDex} from "../src/OneClickPerpDex.sol";

contract InitialPairConfigTest is Test, InitialPairConfig {
    function testSeedBothDexesWithRequestedMarketsAndMatchingRiskSettings() public {
        address collateral = deployCode("MockUSDC.sol:MockUSDC");
        PerpDex perp =
            PerpDex(payable(deployCode("PerpDex.sol:PerpDex", abi.encode(collateral, collateral, collateral))));
        OneClickPerpDex oneClick = OneClickPerpDex(
            payable(deployCode("OneClickPerpDex.sol:OneClickPerpDex", abi.encode(collateral, collateral)))
        );
        _configurePerpDex(perp);
        _configureOneClickPerpDex(oneClick);

        string[12] memory expectedNames = [
            "BTC_USD",
            "ETH_USD",
            "SOL_USD",
            "BNB_USD",
            "HYPE_USD",
            "DOGE_USD",
            "XAU_USD",
            "XAG_USD",
            "USD_JPY",
            "EUR_USD",
            "VOO_USD",
            "QQQ_USD"
        ];
        OneClickPerpDex.PairInfo[] memory pairs = oneClick.getAllPairs();
        assertEq(pairs.length, expectedNames.length);
        uint256 totalWeight;
        for (uint256 i; i < expectedNames.length; i++) {
            PerpDex.PairInfo memory info = perp.allPairs(i);
            assertEq(info.name, expectedNames[i]);
            assertEq(pairs[i].name, info.name);
            assertTrue(info.active && pairs[i].active);
            assertNotEq(info.pythTokenId, bytes32(0));
            // The two seeders use weights scaled by 100, with identical allocations.
            assertEq(pairs[i].liquidityRatio, info.liquidityRatio * 100);
            assertEq(pairs[i].maxPositionSize, info.maxPositionSize);
            assertEq(pairs[i].minLeverage, info.minLeverage);
            assertEq(pairs[i].maxLeverage, info.maxLeverage);
            assertEq(pairs[i].maxTP, info.maxTP);
            assertEq(info.availableLiquidity, 0);
            assertEq(pairs[i].availableLiquidity, 0);
            assertEq(info.usedLiquidity, 0);
            assertEq(pairs[i].usedLiquidity, 0);
            if (i >= 8) {
                assertEq(info.maxLeverage, 100);
                assertEq(info.maxPositionSize, 50_000e6);
            }
            totalWeight += info.liquidityRatio;
        }
        assertEq(perp.totalLiquidityRatio(), totalWeight);
        assertEq(oneClick.totalLiquidityRatio(), totalWeight * 100);
        // Reject any unexpected extra market in the main DEX registry.
        vm.expectRevert();
        perp.allPairs(expectedNames.length);
    }
}
