// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PythStructs} from "pyth-sdk-solidity/PythStructs.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {PerpDex} from "../src/PerpDex.sol";
import {ppUSDC} from "../src/ppUSDC.sol";

contract MaxTPMockPyth {
    PythStructs.Price internal currentPrice;
    uint256 public updateCallCount;

    function setPrice(uint256 price) external {
        _setPrice(price);
    }

    function _setPrice(uint256 price) internal {
        currentPrice = PythStructs.Price({
            price: int64(int256(price)),
            conf: 0,
            expo: 0,
            publishTime: block.timestamp
        });
    }

    function getUpdateFee(
        bytes[] calldata
    ) external pure returns (uint256) {
        return 0;
    }

    // Test-only update format: the first payload is abi.encode(uint256 price).
    function updatePriceFeeds(bytes[] calldata updateData) external payable {
        ++updateCallCount;
        if (updateData.length > 0) {
            _setPrice(abi.decode(updateData[0], (uint256)));
        }
    }

    function getPrice(
        bytes32
    ) external view returns (PythStructs.Price memory) {
        return currentPrice;
    }

    function getPriceUnsafe(
        bytes32
    ) external view returns (PythStructs.Price memory) {
        return currentPrice;
    }
}

contract PerpDexTest is Test {
    uint256 internal constant ENTRY_PRICE = 50_000e8;
    uint256 internal constant MARGIN = 100e6;
    uint256 internal constant LEVERAGE = 10;

    address internal trader = makeAddr("trader");

    MockUSDC internal usdc;
    ppUSDC internal lpToken;
    MaxTPMockPyth internal mockPyth;
    PerpDex internal perpDex;

    function setUp() public {
        usdc = new MockUSDC();
        lpToken = new ppUSDC();
        mockPyth = new MaxTPMockPyth();
        mockPyth.setPrice(ENTRY_PRICE);

        perpDex = new PerpDex(
            address(usdc),
            address(mockPyth),
            address(lpToken)
        );
        perpDex.addPair(
            "BTC_USD",
            bytes32(uint256(1)),
            20,
            50_000e6,
            2,
            100,
            5e18
        );
        lpToken.setMinter(address(perpDex), true);

        usdc.ownerMint(address(this), 100_000_000e6);
        usdc.approve(address(perpDex), type(uint256).max);
        perpDex.depositLP(100_000_000e6);

        usdc.ownerMint(trader, MARGIN * 10);
        vm.prank(trader);
        usdc.approve(address(perpDex), type(uint256).max);
    }

    function testOpenWithoutTPDefaultsToPairMaxTP() public {
        perpDex.updatePairMaxTP("BTC_USD", 2e18); // 200% of margin

        _openLong(0);

        (, , uint256 takeProfit) = _positionData(0);
        // At 10x leverage, 200% ROI is a 20% favorable price move.
        assertEq(takeProfit, 60_000e8);
    }

    function testConstructorDoesNotAddPairs() public {
        PerpDex emptyDex = new PerpDex(
            address(usdc),
            address(mockPyth),
            address(lpToken)
        );
        assertEq(emptyDex.totalOIRatio(), 0);
    }

    function testInitialLpDepositMintsSameDisplayedTokenAmount() public {
        // USDC and ppUSDC are both 6 decimals, so the initial deposit mints
        // the identical displayed number of LP tokens.
        assertEq(lpToken.decimals(), 6);
        assertEq(lpToken.balanceOf(address(this)), 100_000_000e6);
        assertEq(perpDex.calculateDepositShares(10_000e6), 10_000e6);
        assertEq(perpDex.getppUSDCPrice(), 1e18);
    }

    function testFrontendUserLPValueView() public {
        assertEq(perpDex.getUserLPValue(address(this)), 100_000_000e6);
        assertEq(perpDex.getUserLPStakingValue(address(this)), 100_000_000e6);
        assertEq(perpDex.getUserLPValue(trader), 0);
        assertEq(perpDex.getUserLPStakingValue(trader), 0);
    }

    function testUserLPStakingValueUsesPpUSDCShareOfLPStaking() public {
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
        perpDex.updatePairMaxTP("BTC_USD", 1e18); // 100% of margin

        vm.expectRevert("TP exceeds pair maxTP");
        _openLong(56_000e8); // 120% ROI at 10x
    }

    function testShortDefaultAndMaxTPValidation() public {
        perpDex.updatePairMaxTP("BTC_USD", 1e18);

        _openShort(0);
        (, , uint256 takeProfit) = _positionData(0);
        assertEq(takeProfit, 45_000e8);

        vm.expectRevert("TP exceeds pair maxTP");
        _openShort(44_000e8); // 120% ROI at 10x
    }

    function testModifyRejectsTPAbovePairMaxTP() public {
        perpDex.updatePairMaxTP("BTC_USD", 1e18);
        _openLong(0);

        (bytes32 positionId, , ) = _positionData(0);

        vm.prank(trader);
        vm.expectRevert("TP exceeds pair maxTP");
        perpDex.modifyTpSl(positionId, 56_000e8, 0, new bytes[](0));
    }

    function testModifyZeroTPResetsToPairMaxTP() public {
        perpDex.updatePairMaxTP("BTC_USD", 2e18);
        _openLong(55_000e8);

        (bytes32 positionId, , ) = _positionData(0);

        vm.prank(trader);
        perpDex.modifyTpSl(positionId, 0, 0, new bytes[](0));

        (, , uint256 takeProfit) = _positionData(0);
        assertEq(takeProfit, 60_000e8);
    }

    function testCloseCapsProfitAtPairMaxTP() public {
        perpDex.updatePairMaxTP("BTC_USD", 1e18); // Max profit = 100 USDC
        _openLong(0);

        (bytes32 positionId, , ) = _positionData(0);
        mockPyth.setPrice(100_000e8); // Uncapped profit would be 1,000% ROI

        bytes[] memory updateData = new bytes[](0);
        vm.prank(trader);
        perpDex.closePosition(positionId, updateData);

        (, uint256 payout, ) = _positionData(0);
        // 100 margin + 100 capped profit - 2% fee on the 100 profit.
        assertEq(payout, 198e6);
        assertEq(usdc.balanceOf(trader), (MARGIN * 9) + 198e6);
    }

    function testFuzzPairMaxTPAllowsCloseDefaultAtMaxLeverage(bool isLong) public {
        perpDex.addPair("ETH_USD", bytes32(uint256(2)), 20, 50_000e6, 2, 100, 0.05e18);
        perpDex.updatePairMaxTP("BTC_USD", 0.05e18);
        perpDex.updatePairConfig("BTC_USD", 20, 50_000e6, 2, 200);

        vm.prank(trader);
        perpDex.openPosition("BTC_USD", isLong, MARGIN, 200, new bytes[](0), 0, 0);

        (, , uint256 takeProfit) = _positionData(0);
        uint256 priceDelta = (ENTRY_PRICE * 0.05e18) / (1e18 * 200);
        assertLt(priceDelta, ENTRY_PRICE / 1000);
        assertEq(takeProfit, isLong ? ENTRY_PRICE + priceDelta : ENTRY_PRICE - priceDelta);
    }

    function testPairMaxTPSetterStillRejectsZero() public {
        vm.expectRevert("Invalid maxTP");
        perpDex.updatePairMaxTP("BTC_USD", 0);
    }

    function testFuzzOpenAndTriggerCloseTpSl(bool isLong, bool hitTP, uint64 distanceSeed) public {
        uint256 distance = bound(uint256(distanceSeed), 1, ENTRY_PRICE / 1000 - 1);
        uint256 tp = isLong ? ENTRY_PRICE + distance : ENTRY_PRICE - distance;
        uint256 sl = isLong ? ENTRY_PRICE - distance : ENTRY_PRICE + distance;

        vm.prank(trader);
        perpDex.openPosition("BTC_USD", isLong, MARGIN, LEVERAGE, new bytes[](0), tp, sl);

        (bytes32 positionId, bool isClosed, , uint256 storedTP, uint256 storedSL) = _triggerData();
        assertFalse(isClosed);
        assertEq(storedTP, tp);
        assertEq(storedSL, sl);

        vm.expectRevert("No TP/SL triggered");
        perpDex.triggerTpSl(trader, positionId, new bytes[](0));

        uint256 triggerPrice = hitTP ? tp : sl;
        mockPyth.setPrice(triggerPrice);
        perpDex.triggerTpSl(trader, positionId, new bytes[](0));

        (, isClosed, triggerPrice, , ) = _triggerData();
        assertTrue(isClosed);
        assertEq(triggerPrice, hitTP ? tp : sl);
    }

    function testFuzzModifyAndTriggerCloseTpSl(
        bool isLong, bool hitTP, bool priceMoved, uint64 distanceSeed
    ) public {
        if (isLong) _openLong(0);
        else _openShort(0);
        (bytes32 positionId, , ) = _positionData(0);

        uint256 currentPrice = priceMoved
            ? (isLong ? ENTRY_PRICE + 1_000e8 : ENTRY_PRICE - 1_000e8)
            : ENTRY_PRICE;
        uint256 distance = bound(uint256(distanceSeed), 1, currentPrice / 1000 - 1);
        uint256 tp = isLong ? currentPrice + distance : currentPrice - distance;
        uint256 sl = isLong ? currentPrice - distance : currentPrice + distance;
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = abi.encode(currentPrice);

        vm.prank(trader);
        perpDex.modifyTpSl(positionId, tp, sl, updateData);

        (, bool isClosed, , uint256 storedTP, uint256 storedSL) = _triggerData();
        assertFalse(isClosed);
        assertEq(storedTP, tp);
        assertEq(storedSL, sl);
        assertEq(mockPyth.updateCallCount(), 2);

        uint256 triggerPrice = hitTP ? tp : sl;
        mockPyth.setPrice(triggerPrice);
        perpDex.triggerTpSl(trader, positionId, new bytes[](0));

        (, isClosed, triggerPrice, , ) = _triggerData();
        assertTrue(isClosed);
        assertEq(triggerPrice, hitTP ? tp : sl);
    }

    function testWorstCaseProfitCapLimitsExposureToThirtyPercentOfPool() public {
        (PerpDex limitedDex, ) = _deployLimitedDex(1_000e6);

        // At a 500% max TP, 100 USDC margin reserves 500 USDC of LP loss.
        // The 1,000 USDC pool only permits 300 USDC of worst-case loss.
        vm.prank(trader);
        vm.expectRevert("Exceeds 30% worst-case loss limit");
        limitedDex.openPosition(
            "BTC_USD",
            true,
            100e6,
            2,
            new bytes[](0),
            0,
            0
        );
    }

    function testTpCloseAtThirtyPercentDrawdownPausesNewTrading() public {
        (PerpDex limitedDex, ) = _deployLimitedDex(1_000e6);

        vm.prank(trader);
        limitedDex.openPosition(
            "BTC_USD",
            true,
            60e6,
            2,
            new bytes[](0),
            0,
            0
        );

        (bytes32 positionId, , ) = _positionDataFor(limitedDex, 0);
        // 5x margin profit at 2x leverage: 50,000 -> 175,000.
        mockPyth.setPrice(175_000e8);
        vm.prank(trader);
        limitedDex.closePosition(positionId, new bytes[](0));

        assertTrue(limitedDex.tradingPaused());
        assertTrue(limitedDex.pairPaused("BTC_USD"));
        assertEq(limitedDex.getPoolValue(), 700e6);

        vm.prank(trader);
        vm.expectRevert("Trading paused");
        limitedDex.openPosition(
            "BTC_USD",
            true,
            1e6,
            2,
            new bytes[](0),
            0,
            0
        );
    }

    function testDailySnapshotRequiresOneDayAndRefreshesBaseline() public {
        vm.expectRevert("Snapshot not due");
        perpDex.snapshotLiquidityPool();

        vm.warp(block.timestamp + 1 days);
        uint256 snapshot = perpDex.snapshotLiquidityPool();
        assertEq(snapshot, perpDex.getPoolValue());
        assertEq(perpDex.latestLiquiditySnapshot(), snapshot);
    }

    function testPausedPairBlocksCloseButAllowsPriceValidatedTpSlEdit() public {
        _openLong(0);
        (bytes32 positionId, , ) = _positionData(0);
        perpDex.setPairPaused("BTC_USD", true);

        vm.prank(trader);
        vm.expectRevert("Pair paused");
        perpDex.closePosition(positionId, new bytes[](0));

        // The stored Pyth price is 50,000, so both levels are valid.
        vm.prank(trader);
        perpDex.modifyTpSl(positionId, 55_000e8, 45_000e8, new bytes[](0));

        (, , uint256 takeProfit) = _positionData(0);
        assertEq(takeProfit, 55_000e8);
    }

    function testTpSlEditRejectsLevelOnWrongSideOfCurrentPrice() public {
        _openLong(0);
        (bytes32 positionId, , ) = _positionData(0);

        vm.prank(trader);
        vm.expectRevert("Long TP must be above current price");
        perpDex.modifyTpSl(positionId, 49_000e8, 0, new bytes[](0));
    }

    function testTpSlEditValidatesAgainstFrontendPythUpdate() public {
        _openLong(0);
        (bytes32 positionId, , ) = _positionData(0);

        bytes[] memory priceUpdateData = new bytes[](1);
        // The mock accepts abi.encode(price) as a price-feed update. A 52,000
        // TP would be valid against the previously stored 50,000 price, but
        // must fail after this frontend-supplied update moves it to 55,000.
        priceUpdateData[0] = abi.encode(55_000e8);

        vm.prank(trader);
        vm.expectRevert("Long TP must be above current price");
        perpDex.modifyTpSl(positionId, 52_000e8, 0, priceUpdateData);
    }

    function _triggerData() internal view returns (
        bytes32 id, bool isClosed, uint256 closePrice, uint256 takeProfit, uint256 stopLoss
    ) {
        (
            id,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            isClosed,
            closePrice,
            ,
            ,
            ,
            ,
            takeProfit,
            stopLoss
        ) = perpDex.positions(trader, 0);
    }

    function _openLong(uint256 takeProfit) internal {
        bytes[] memory updateData = new bytes[](0);
        vm.prank(trader);
        perpDex.openPosition(
            "BTC_USD",
            true,
            MARGIN,
            LEVERAGE,
            updateData,
            takeProfit,
            0
        );
    }

    function _openShort(uint256 takeProfit) internal {
        bytes[] memory updateData = new bytes[](0);
        vm.prank(trader);
        perpDex.openPosition(
            "BTC_USD",
            false,
            MARGIN,
            LEVERAGE,
            updateData,
            takeProfit,
            0
        );
    }

    function _positionData(
        uint256 index
    ) internal view returns (bytes32 id, uint256 payout, uint256 takeProfit) {
        (
            id,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            payout,
            ,
            ,
            ,
            takeProfit,

        ) = perpDex.positions(trader, index);
    }

    function _deployLimitedDex(
        uint256 liquidity
    ) internal returns (PerpDex limitedDex, ppUSDC limitedLp) {
        limitedLp = new ppUSDC();
        limitedDex = new PerpDex(
            address(usdc),
            address(mockPyth),
            address(limitedLp)
        );
        limitedDex.addPair(
            "BTC_USD",
            bytes32(uint256(1)),
            20,
            50_000e6,
            2,
            100,
            5e18
        );
        limitedLp.setMinter(address(limitedDex), true);

        usdc.ownerMint(address(this), liquidity);
        usdc.approve(address(limitedDex), liquidity);
        limitedDex.depositLP(liquidity);

        usdc.ownerMint(trader, 1_000e6);
        vm.prank(trader);
        usdc.approve(address(limitedDex), type(uint256).max);
    }

    function _positionDataFor(
        PerpDex dex,
        uint256 index
    ) internal view returns (bytes32 id, uint256 payout, uint256 takeProfit) {
        (
            id,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            payout,
            ,
            ,
            ,
            takeProfit,

        ) = dex.positions(trader, index);
    }
}
