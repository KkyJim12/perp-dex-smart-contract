// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PredictionMarketAMM} from "../src/PredictionMarketAMM.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {PythStructs} from "lib/pyth-sdk-solidity/PythStructs.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

contract PredictionOracleMock {
    bytes32 constant FEED = bytes32(uint256(1));
    PythStructs.Price public spot;
    bytes32 public returnedFeed = FEED;
    uint256 public updateFee;

    function setFee(uint256 fee) external {
        updateFee = fee;
    }

    function setReturnedFeed(bytes32 id) external {
        returnedFeed = id;
    }

    function setSpot(int64 price, uint64 conf, int32 expo, uint256 time) external {
        spot = PythStructs.Price(price, conf, expo, time);
    }

    function getUpdateFee(bytes[] calldata) external view returns (uint256) {
        return updateFee;
    }

    function updatePriceFeeds(bytes[] calldata data) external payable {
        require(msg.value == updateFee, "Oracle fee");
        if (data.length != 0) spot = abi.decode(data[0], (PythStructs.Price));
    }

    function getPriceNoOlderThan(bytes32 id, uint256) external view returns (PythStructs.Price memory) {
        require(id == returnedFeed, "Wrong spot feed");
        // Deliberately leave freshness validation to the vault in these tests.
        return spot;
    }
}

contract PredictionTransferMock is MockUSDC {
    address public blockedRecipient;
    bool public chargeTransferFee;
    address public reentryTarget;
    bool public reentryBlocked;

    function setBlocked(address recipient) external {
        blockedRecipient = recipient;
    }

    function setChargeTransferFee(bool value) external {
        chargeTransferFee = value;
    }

    function setReentryTarget(address target) external {
        reentryTarget = target;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        require(to != blockedRecipient, "Recipient blocked");
        if (reentryTarget != address(0)) {
            (bool ok,) =
                reentryTarget.call(abi.encodeWithSignature("resolveMarket(uint256,bytes[])", 0, new bytes[](0)));
            reentryBlocked = !ok;
        }
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool ok = super.transferFrom(from, to, value);
        if (chargeTransferFee) _burn(to, 1);
        return ok;
    }
}

contract PredictionMarketAMMTest is Test {
    PredictionMarketAMM amm;
    PredictionTransferMock usdc;
    PredictionOracleMock pyth;
    address lp = makeAddr("lp");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    bytes32 constant FEED = bytes32(uint256(1));
    uint256 constant OPEN = 100e18;

    function setUp() public {
        vm.warp(1);
        usdc = new PredictionTransferMock();
        pyth = new PredictionOracleMock();
        amm = new PredictionMarketAMM(address(usdc), address(pyth), 300);
        amm.addPair("BTC_USD", FEED);
        _fund(lp, 100_000e6);
        _fund(alice, 20_000e6);
        _fund(bob, 20_000e6);
        vm.prank(lp);
        amm.deposit(100_000e6, 100_000e6);
        amm.createMarket(0, 300, 10_000);
        vm.warp(300);
        pyth.setSpot(100, 0, 0, 300);
        amm.openMarket(0, new bytes[](0));
    }

    function _fund(address user, uint256 assets) internal {
        usdc.ownerMint(user, assets);
        vm.prank(user);
        usdc.approve(address(amm), type(uint256).max);
    }

    function _buy(address user, uint256 id, bool up, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        return amm.buy(id, up, assets, OPEN, 0, block.timestamp, new bytes[](0));
    }

    function _resolve(uint256 id, int64 price, uint256 time) internal {
        vm.warp(time);
        pyth.setSpot(price, 0, 0, time);
        amm.resolveMarket(id, new bytes[](0));
    }

    function testEvenOddsIncludeThreePercentEdge() public view {
        (uint256 payout, uint256 fee) = amm.quoteBuy(0, true, 100e6, OPEN);
        assertEq(payout, 194e6);
        assertEq(fee, 3e6);
        assertEq(amm.winProbability(0, true, OPEN), 5e17);
        (uint256 downPayout,) = amm.quoteBuy(0, false, 100e6, OPEN);
        assertEq(downPayout, payout);
    }

    function testPriceTimeAndVolatilityChangeOdds() public {
        (uint256 up,) = amm.quoteBuy(0, true, 100e6, 100.1e18);
        (uint256 down,) = amm.quoteBuy(0, false, 100e6, 100.1e18);
        assertLt(up, 194e6);
        assertGt(down, 194e6);
        assertEq(amm.winProbability(0, true, 100.1e18) + amm.winProbability(0, false, 100.1e18), 1e18);
        vm.warp(540);
        (uint256 laterUp,) = amm.quoteBuy(0, true, 100e6, 100.1e18);
        assertLt(laterUp, up);

        uint256 high = amm.createMarket(0, 900, 20_000);
        vm.warp(900);
        pyth.setSpot(100, 0, 0, 900);
        amm.openMarket(high, new bytes[](0));
        vm.warp(1500); // same 300 seconds remaining as the original quote
        (uint256 highVolUp,) = amm.quoteBuy(high, true, 100e6, 100.1e18);
        assertGt(highVolUp, up);
        assertEq(amm.getMarket(high).volatilityBps, 20_000);
    }

    function testPayoutLockedAtPurchaseAndUsesRoundOpeningThreshold() public {
        uint256 payout = _buy(alice, 0, true, 100e6);
        vm.warp(400);
        pyth.setSpot(100_100, 0, -3, 400); // 100.1 USD
        (uint256 quote,) = amm.quoteBuy(0, true, 100e6, 100.1e18);
        vm.prank(bob);
        uint256 second = amm.buy(0, true, 100e6, 100.1e18, quote, 400, new bytes[](0));
        assertLt(second, payout);
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);
        _resolve(0, 100, 600); // equality wins Up despite Bob entering above opening
        assertEq(usdc.balanceOf(alice), aliceBefore + payout);
        assertEq(usdc.balanceOf(bob), bobBefore + second);
        assertEq(amm.upBalance(0, alice), 0);
        assertEq(amm.upBalance(0, bob), 0);
        assertEq(amm.reservedPayout(), 0);
        assertEq(amm.unresolvedExposureMarkets(), 0);
        assertEq(amm.getMarket(0).upOutstanding, 0);
        vm.expectRevert("Not resolvable");
        amm.resolveMarket(0, new bytes[](0));
    }

    function testMixedBetsPayWinningBalancesOnceAndVaultOwnsPL() public {
        _buy(alice, 0, true, 100e6);
        _buy(alice, 0, true, 25e6);
        uint256 aliceWin = _buy(alice, 0, false, 50e6);
        uint256 bobWin = _buy(bob, 0, false, 100e6);
        assertEq(amm.traderCount(0), 2);
        assertEq(amm.traders(0, 0), alice);
        assertEq(amm.reservedPayout(), aliceWin + bobWin);
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);
        _resolve(0, 99, 600);
        assertEq(usdc.balanceOf(alice), aliceBefore + aliceWin);
        assertEq(usdc.balanceOf(bob), bobBefore + bobWin);
        assertEq(amm.vaultValue(), 100_000e6 + 275e6 - aliceWin - bobWin);
        assertEq(amm.upBalance(0, alice), 0);
        assertEq(amm.downBalance(0, alice), 0);
        assertEq(amm.downBalance(0, bob), 0);
        assertEq(amm.getMarket(0).downOutstanding, 0);
        uint256 lpShares = amm.shareToken().balanceOf(lp);
        uint256 lpAssets = amm.previewRedeem(lpShares);
        vm.prank(lp);
        amm.withdraw(lpShares, lpAssets);
        assertEq(usdc.balanceOf(lp), lpAssets);
    }

    function testBalancedOppositeBetsLeaveEdgeInVaultForEitherOutcome() public {
        uint256 first = _buy(alice, 0, true, 100e6);
        uint256 second = _buy(bob, 0, false, 100e6);
        assertEq(first, second);
        assertEq(amm.reservedPayout(), first); // mutually exclusive outcomes hedge each other
        _resolve(0, 100, 600);
        assertEq(amm.vaultValue(), 100_006e6);
        assertEq(amm.totalFees(), 6e6);
    }

    function testSellClaimAndOutcomeTransferAreUnavailable() public {
        _buy(alice, 0, true, 100e6);
        (bool sold,) = address(amm)
            .call(abi.encodeWithSignature("sell(uint256,bool,uint256,uint256,uint256)", 0, true, 10e6, 100e6, 300));
        (bool claimed,) = address(amm).call(abi.encodeWithSignature("claim(uint256,address)", 0, alice));
        (bool transferred,) = address(amm).call(abi.encodeWithSignature("transfer(address,uint256)", bob, 100e6));
        assertFalse(sold);
        assertFalse(claimed);
        assertFalse(transferred);
        assertEq(amm.upBalance(0, alice), 194e6);
    }

    function testLPsLockedAcrossMultipleExposedMarkets() public {
        uint256 second = amm.createMarket(0, 900, 10_000);
        _buy(alice, 0, true, 100e6);
        vm.prank(lp);
        vm.expectRevert("Unresolved markets lock LPs");
        amm.withdraw(1e6, 0);
        vm.prank(bob);
        vm.expectRevert("Unresolved markets lock LPs");
        amm.deposit(1e6, 0);
        vm.warp(900);
        pyth.setSpot(100, 0, 0, 900);
        amm.openMarket(second, new bytes[](0));
        uint256 secondPayout = _buy(bob, second, false, 200e6);
        assertEq(amm.unresolvedExposureMarkets(), 2);
        amm.resolveMarket(0, new bytes[](0));
        assertEq(amm.reservedPayout(), secondPayout);
        assertEq(amm.unresolvedExposureMarkets(), 1);
        vm.prank(lp);
        vm.expectRevert("Unresolved markets lock LPs");
        amm.withdraw(1e6, 0);
        _resolve(second, 99, 1800);
        assertEq(amm.reservedPayout(), 0);
        assertEq(amm.unresolvedExposureMarkets(), 0);
    }

    function testBuyRejectsForgedPriceSlippageAndExpiredDeadline() public {
        vm.prank(alice);
        vm.expectRevert("Price mismatch");
        amm.buy(0, true, 100e6, 99e18, 0, 300, new bytes[](0));
        vm.prank(alice);
        vm.expectRevert("Share slippage");
        amm.buy(0, true, 100e6, OPEN, 194e6 + 1, 300, new bytes[](0));
        vm.prank(alice);
        vm.expectRevert("Deadline passed");
        amm.buy(0, true, 100e6, OPEN, 0, 299, new bytes[](0));
        assertEq(amm.traderCount(0), 0);
        assertEq(amm.reservedPayout(), 0);
    }

    function testSubmittedPriceUpdateIsConsumedAndFeeIsExact() public {
        pyth.setFee(1);
        vm.deal(alice, 1 ether);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(PythStructs.Price(100_100, 0, -3, 300));
        vm.prank(alice);
        vm.expectRevert("Incorrect Pyth fee");
        amm.buy(0, true, 100e6, 100.1e18, 0, 300, data);
        vm.prank(alice);
        uint256 payout = amm.buy{value: 1}(0, true, 100e6, 100.1e18, 0, 300, data);
        assertLt(payout, 194e6);
        assertEq(address(pyth).balance, 1);
        vm.warp(600);
        pyth.setSpot(100, 0, 0, 600);
        vm.expectRevert("Incorrect Pyth fee");
        amm.resolveMarket(0, new bytes[](0));
        vm.deal(address(this), 1);
        amm.resolveMarket{value: 1}(0, new bytes[](0));
    }

    function testStaleFuturePreRoundAndUncertainPricesRejected() public {
        vm.warp(400);
        pyth.setSpot(100, 0, 0, 394);
        vm.expectRevert("Invalid publish time");
        _buy(alice, 0, true, 100e6);
        pyth.setSpot(100, 0, 0, 401);
        vm.expectRevert("Invalid publish time");
        _buy(alice, 0, true, 100e6);
        vm.warp(301);
        pyth.setSpot(100, 0, 0, 299);
        vm.expectRevert("Invalid publish time");
        _buy(alice, 0, true, 100e6);
        pyth.setSpot(100, 2, 0, 301);
        vm.expectRevert("Uncertain price");
        _buy(alice, 0, true, 100e6);
        pyth.setSpot(-100, 0, 0, 301);
        vm.expectRevert("Invalid price");
        _buy(alice, 0, true, 100e6);
        pyth.setSpot(100, 0, -19, 301);
        vm.expectRevert("Invalid price");
        _buy(alice, 0, true, 100e6);
    }

    function testSettlementFeedTimeAndConfidenceValidated() public {
        vm.expectRevert("Not resolvable");
        amm.resolveMarket(0, new bytes[](0));
        vm.warp(650);
        pyth.setSpot(100, 0, 0, 599);
        vm.expectRevert("Invalid publish time");
        amm.resolveMarket(0, new bytes[](0));
        pyth.setSpot(100, 0, 0, 631);
        vm.expectRevert("Invalid publish time");
        amm.resolveMarket(0, new bytes[](0));
        pyth.setSpot(100, 0, 0, 651);
        vm.expectRevert("Invalid publish time");
        amm.resolveMarket(0, new bytes[](0));
        pyth.setSpot(100, 2, 0, 650);
        vm.expectRevert("Uncertain price");
        amm.resolveMarket(0, new bytes[](0));
        pyth.setSpot(100, 0, 0, 650);
        pyth.setReturnedFeed(bytes32(uint256(2)));
        vm.expectRevert("Wrong spot feed");
        amm.resolveMarket(0, new bytes[](0));
    }

    function testWorkerCreatesAndOpensRoundAtAnyTime() public {
        amm.authorizeBackend(bob, true);
        vm.warp(312);
        vm.prank(bob);
        uint256 id = amm.createMarket(0, 300, 10_000);
        assertEq(amm.getMarket(id).startTime, 0);
        assertEq(amm.getMarket(id).endTime, 0);
        assertEq(amm.getMarket(id).duration, 300);
        // Creating another round at the same time is allowed.
        amm.createMarket(0, 300, 10_000);
        vm.warp(90_123);
        pyth.setSpot(100, 0, 0, 90_117);
        vm.expectRevert("Invalid publish time");
        amm.openMarket(id, new bytes[](0));
        assertEq(amm.getMarket(id).startTime, 0);
        pyth.setSpot(100, 0, 0, 90_124);
        vm.expectRevert("Invalid publish time");
        amm.openMarket(id, new bytes[](0));
        pyth.setSpot(100, 0, 0, 90_118);
        vm.prank(bob);
        amm.openMarket(id, new bytes[](0));
        assertEq(amm.getMarket(id).startTime, 90_123);
        assertEq(amm.getMarket(id).endTime, 90_423);
        vm.expectRevert("Not scheduled");
        amm.openMarket(id, new bytes[](0));
        vm.expectRevert("Not resolvable");
        amm.resolveMarket(id, new bytes[](0));
        vm.warp(90_423);
        pyth.setSpot(100, 0, 0, 90_422);
        vm.expectRevert("Invalid publish time");
        amm.resolveMarket(id, new bytes[](0));
        _resolve(id, 101, 90_999);
        assertEq(amm.getMarket(id).closingPrice, 101e18);
    }

    function testWorkerAuthorizationAndRevocation() public {
        vm.prank(alice);
        vm.expectRevert("Not authorized backend");
        amm.createMarket(0, 300, 10_000);
        uint256 id = amm.createMarket(0, 300, 10_000);
        vm.prank(alice);
        vm.expectRevert("Not authorized backend");
        amm.openMarket(id, new bytes[](0));
        vm.prank(alice);
        vm.expectRevert();
        amm.authorizeBackend(alice, true);
        vm.expectRevert("Invalid backend");
        amm.authorizeBackend(address(0), true);
        amm.authorizeBackend(bob, true);
        vm.prank(bob);
        amm.openMarket(id, new bytes[](0));
        amm.authorizeBackend(bob, false);
        vm.warp(600);
        pyth.setSpot(100, 0, 0, 600);
        vm.prank(bob);
        vm.expectRevert("Not authorized backend");
        amm.resolveMarket(id, new bytes[](0));
        amm.resolveMarket(id, new bytes[](0));
    }

    function testLifecycleConsumesSignedUpdatesAndChargesExactFee() public {
        uint256 id = amm.createMarket(0, 300, 10_000);
        pyth.setFee(1);
        vm.deal(address(this), 2);
        bytes[] memory data = new bytes[](1);
        vm.warp(333);
        data[0] = abi.encode(PythStructs.Price(102, 0, 0, 331));
        vm.expectRevert("Incorrect Pyth fee");
        amm.openMarket(id, data);
        assertEq(amm.getMarket(id).startTime, 0);
        amm.openMarket{value: 1}(id, data);
        assertEq(amm.getMarket(id).openingPrice, 102e18);
        assertEq(amm.getMarket(id).endTime, 633);
        vm.warp(999);
        data[0] = abi.encode(PythStructs.Price(101, 0, 0, 997));
        amm.resolveMarket{value: 1}(id, data);
        assertEq(amm.getMarket(id).closingPrice, 101e18);
        assertFalse(amm.getMarket(id).upWins);
        assertEq(address(pyth).balance, 2);
    }

    function testPauseAndCutoffStopBetsButAllowResolution() public {
        _buy(alice, 0, true, 100e6);
        amm.setTradingPaused(true);
        vm.expectRevert("Trading paused");
        _buy(bob, 0, false, 100e6);
        _resolve(0, 100, 600);
        assertEq(amm.reservedPayout(), 0);
    }

    function testTradingCutoffAndOddsLimits() public {
        vm.expectRevert("Odds outside limits");
        amm.quoteBuy(0, true, 100e6, 200e18);
        vm.expectRevert("Odds outside limits");
        amm.quoteBuy(0, false, 100e6, 200e18);
        vm.expectRevert("Invalid price");
        amm.quoteBuy(0, true, 100e6, 0);
        vm.expectRevert("Trade too small");
        amm.quoteBuy(0, true, 1, OPEN);
        vm.warp(595);
        vm.expectRevert("Market closed");
        _buy(alice, 0, true, 100e6);
    }

    function testInsufficientCollateralAndTransferFeeRollback() public {
        _fund(alice, 100_000e6);
        uint256 beforeBalance = usdc.balanceOf(alice);
        vm.expectRevert("Vault utilization exceeded");
        _buy(alice, 0, true, 100_000e6);
        assertEq(usdc.balanceOf(alice), beforeBalance);
        assertEq(amm.reservedPayout(), 0);
        assertEq(amm.unresolvedExposureMarkets(), 0);
        assertEq(amm.traderCount(0), 0);
        usdc.setChargeTransferFee(true);
        vm.expectRevert("Unsupported transfer fee");
        _buy(alice, 0, true, 100e6);
        assertEq(amm.upBalance(0, alice), 0);
        assertEq(amm.totalFees(), 0);
    }

    function testBlockedWinnerRevertsWholeResolutionWithoutLosingBalances() public {
        _buy(alice, 0, true, 100e6);
        _buy(bob, 0, true, 100e6);
        usdc.setBlocked(bob);
        vm.warp(600);
        pyth.setSpot(100, 0, 0, 600);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.expectRevert("Recipient blocked");
        amm.resolveMarket(0, new bytes[](0));
        assertEq(usdc.balanceOf(alice), aliceBefore);
        assertEq(amm.upBalance(0, alice), 194e6);
        assertEq(amm.upBalance(0, bob), 194e6);
        assertEq(amm.reservedPayout(), 388e6);
        assertEq(uint256(amm.getMarket(0).status), uint256(PredictionMarketAMM.Status.Trading));
        usdc.setBlocked(address(0));
        amm.resolveMarket(0, new bytes[](0));
        assertEq(amm.reservedPayout(), 0);
    }

    function testSettlementReentrancyRejected() public {
        _buy(alice, 0, true, 100e6);
        usdc.setReentryTarget(address(amm));
        _resolve(0, 100, 600);
        assertTrue(usdc.reentryBlocked());
        assertEq(amm.reservedPayout(), 0);
    }

    function testMaximumParticipantsResolveWithinGasBudget() public {
        uint256 count = amm.MAX_TRADERS_PER_MARKET();
        for (uint256 i; i < count; ++i) {
            address trader = address(uint160(1000 + i));
            _fund(trader, 10e6);
            _buy(trader, 0, true, 10e6);
        }
        assertEq(amm.traderCount(0), count);
        vm.expectRevert("Market participant limit");
        _buy(alice, 0, true, 10e6);
        _fund(address(1000), 10e6);
        _buy(address(1000), 0, false, 10e6); // existing holder can add at the cap
        assertEq(amm.traderCount(0), count);
        vm.warp(600);
        pyth.setSpot(100, 0, 0, 600);
        uint256 startGas = gasleft();
        amm.resolveMarket(0, new bytes[](0));
        uint256 used = startGas - gasleft();
        emit log_named_uint("128-holder settlement gas (mock USDC)", used);
        assertLt(used, 8_000_000);
        for (uint256 i; i < count; ++i) {
            address trader = address(uint160(1000 + i));
            assertEq(usdc.balanceOf(trader), 19.4e6);
            assertEq(amm.upBalance(0, trader), 0);
            assertEq(amm.downBalance(0, trader), 0);
        }
        assertEq(amm.reservedPayout(), 0);
    }

    function testResolveEmptyMarketAndNoWinningHolders() public {
        _resolve(0, 100, 600);
        assertEq(amm.unresolvedExposureMarkets(), 0);
        uint256 id = amm.createMarket(0, 300, 10_000);
        vm.warp(900);
        pyth.setSpot(100, 0, 0, 900);
        amm.openMarket(id, new bytes[](0));
        _buy(alice, id, false, 100e6);
        _resolve(id, 100, 1200);
        assertEq(amm.vaultValue(), 100_100e6);
        assertEq(amm.downBalance(id, alice), 0);
    }

    function testInvalidVolatilityRejected() public {
        vm.expectRevert("Invalid volatility");
        amm.createMarket(0, 300, 99);
        vm.expectRevert("Invalid volatility");
        amm.createMarket(0, 300, 50_001);
    }

    function testFuzzPayoutConservationAndExpectedEdge(uint96 rawAssets, bool up, bool upWins) public {
        uint256 assets = bound(uint256(rawAssets), 100, 10_000e6);
        uint256 payout = _buy(alice, 0, up, assets);
        uint256 fee = Math.mulDiv(assets, 300, 10_000, Math.Rounding.Ceil);
        assertEq(payout, (assets - fee) * 2);
        assertGt(payout, assets);
        assertEq(amm.totalFees(), fee);
        assertEq(amm.reservedPayout(), payout);
        uint256 aliceBefore = usdc.balanceOf(alice);
        _resolve(0, upWins ? int64(100) : int64(99), 600);
        uint256 actual = up == upWins ? payout : 0;
        assertEq(usdc.balanceOf(alice), aliceBefore + actual);
        assertEq(amm.vaultValue(), 100_000e6 + assets - actual);
        assertEq(amm.reservedPayout(), 0);
    }

    function testFuzzOddsMonotonicAndEdge(uint32 rawMovement, uint96 rawAssets) public view {
        uint256 spot = OPEN + bound(uint256(rawMovement), 0, 20_000_000) * 1e10;
        uint256 assets = bound(uint256(rawAssets), 100e6, 1000e6);
        uint256 probability = amm.winProbability(0, true, spot);
        (uint256 payout, uint256 fee) = amm.quoteBuy(0, true, assets, spot);
        assertGe(probability, 5e17);
        assertLe(payout, Math.mulDiv(assets - fee, 2, 1));
        assertLe(Math.mulDiv(payout, probability, 1e18), assets - fee);
    }
}

/// @dev Purchases happen in setUp so resolution measures committed balances in a separate test call.
contract PredictionMarketSettlementGasTest is Test {
    PredictionMarketAMM amm;
    PredictionTransferMock usdc;
    PredictionOracleMock pyth;

    function setUp() public {
        vm.warp(1);
        usdc = new PredictionTransferMock();
        pyth = new PredictionOracleMock();
        amm = new PredictionMarketAMM(address(usdc), address(pyth), 300);
        amm.addPair("BTC_USD", bytes32(uint256(1)));
        usdc.ownerMint(address(this), 10_000e6);
        usdc.approve(address(amm), type(uint256).max);
        amm.deposit(10_000e6, 0);
        amm.createMarket(0, 300, 10_000);
        vm.warp(300);
        pyth.setSpot(100, 0, 0, 300);
        amm.openMarket(0, new bytes[](0));
        for (uint256 i; i < 128; ++i) {
            address holder = address(uint160(1000 + i));
            usdc.ownerMint(holder, 10e6);
            vm.startPrank(holder);
            usdc.approve(address(amm), type(uint256).max);
            amm.buy(0, true, 10e6, 100e18, 0, 300, new bytes[](0));
            vm.stopPrank();
        }
        vm.warp(600);
        pyth.setSpot(100, 0, 0, 600);
    }

    function testResolveColdMaximumWinningRecipients() public {
        vm.cool(address(amm));
        vm.cool(address(usdc));
        vm.cool(address(pyth));
        uint256 startGas = gasleft();
        amm.resolveMarket(0, new bytes[](0));
        uint256 used = startGas - gasleft();
        emit log_named_uint("Cold 128-winner settlement gas (mock USDC)", used);
        assertLt(used, 8_000_000);
        assertEq(amm.reservedPayout(), 0);
        assertEq(usdc.balanceOf(address(1000)), 19.4e6);
        assertEq(usdc.balanceOf(address(1127)), 19.4e6);
    }
}
