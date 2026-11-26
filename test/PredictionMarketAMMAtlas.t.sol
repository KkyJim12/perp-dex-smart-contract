// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PredictionMarketAMMAtlas} from "../src/PredictionMarketAMMAtlas.sol";
import {PredictionMarketAMM} from "../src/PredictionMarketAMM.sol";
import {AtlasSignedTest} from "./helpers/AtlasSignedTest.sol";
import {AtlasTransferMock} from "./helpers/AtlasTransferMock.sol";
import {AtlasParityPyth} from "./helpers/AtlasParityPyth.sol";

contract PredictionMarketAMMAtlasTest is AtlasSignedTest {
    PredictionMarketAMMAtlas amm;
    AtlasTransferMock usdc;
    address lp = makeAddr("atlas-prediction-lp");
    address alice = makeAddr("atlas-prediction-alice");
    address bob = makeAddr("atlas-prediction-bob");
    uint256 constant OPEN = 100e18;

    function setUp() public {
        vm.warp(1);
        usdc = AtlasTransferMock(deployCode("AtlasTransferMock.sol:AtlasTransferMock"));
        amm = PredictionMarketAMMAtlas(
            deployCode(
                "PredictionMarketAMMAtlas.sol:PredictionMarketAMMAtlas",
                abi.encode(address(usdc), vm.addr(ATLAS_KEY), uint256(300))
            )
        );
        amm.addPair("BTC_USD", BTC);
        amm.authorizeBackend(bob, true);
        _fund(lp, 100_000e6);
        _fund(alice, 20_000e6);
        _fund(bob, 20_000e6);
        vm.prank(lp);
        amm.deposit(100_000e6, 100_000e6);
        amm.createMarket(0, 300, 10_000);
        vm.warp(300);
        _execute(address(amm), bob, abi.encodeCall(amm.openMarket, (0)), _payload(BTC, OPEN, 300));
    }

    function testEvenOddsAndThreePercentEdgePreserved() public view {
        (uint256 payout, uint256 fee) = amm.quoteBuy(0, true, 100e6, OPEN);
        assertEq(payout, 194e6);
        assertEq(fee, 3e6);
        assertEq(amm.winProbability(0, true, OPEN), 5e17);
        assertEq(amm.shareToken().vault(), address(amm));
    }

    function testPayoutsUseOpeningThresholdAndEqualityWinsUp() public {
        uint256 first = _buy(alice, 0, true, 100e6, OPEN);
        vm.warp(400);
        uint256 second = _buy(bob, 0, true, 100e6, 100.1e18);
        assertLt(second, first);
        _resolve(0, OPEN, 600);
        assertEq(usdc.balanceOf(alice), 19_900e6 + first);
        assertEq(usdc.balanceOf(bob), 19_900e6 + second);
        assertEq(amm.upBalance(0, alice), 0);
        assertEq(amm.upBalance(0, bob), 0);
        assertEq(amm.reservedPayout(), 0);
        assertEq(amm.unresolvedExposureMarkets(), 0);
        assertTrue(amm.getMarket(0).upWins);
    }

    function testFuzzPayoutConservationAndVaultEdge(bool upWins, uint64 assetsSeed) public {
        uint256 assets = bound(uint256(assetsSeed), 1e6, 1_000e6);
        uint256 upPayout = _buy(alice, 0, true, assets, OPEN);
        uint256 downPayout = _buy(bob, 0, false, assets, OPEN);
        assertEq(upPayout, downPayout);
        assertEq(amm.reservedPayout(), upPayout);
        _resolve(0, upWins ? OPEN : OPEN - 1, 600);
        assertEq(usdc.balanceOf(address(amm)), 100_000e6 + 2 * assets - upPayout);
        assertEq(amm.vaultValue(), usdc.balanceOf(address(amm)));
        assertEq(amm.totalFees(), 2 * ((assets * 300 + 9_999) / 10_000));
        assertEq(amm.reservedPayout(), 0);
    }

    function testWorkerOpensAtAnyTimeAndDurationStartsOnOpening() public {
        uint256 id = amm.createMarket(0, 300, 10_000);
        assertEq(amm.getMarket(id).startTime, 0);
        assertEq(amm.getMarket(id).endTime, 0);
        assertEq(amm.getMarket(id).duration, 300);
        vm.warp(90_123);
        _execute(address(amm), bob, abi.encodeCall(amm.openMarket, (id)), _payload(BTC, OPEN, 90_118));
        assertEq(amm.getMarket(id).startTime, 90_123);
        assertEq(amm.getMarket(id).endTime, 90_423);
        _reject(
            address(amm),
            bob,
            abi.encodeCall(amm.openMarket, (id)),
            _payload(BTC, OPEN, 90_118),
            _reason("Not scheduled")
        );
    }

    function testDelayedResolutionUsesFreshPriceAndReleasesOnlyItsReserve() public {
        _buy(alice, 0, true, 100e6, OPEN);
        uint256 second = amm.createMarket(0, 900, 10_000);
        vm.warp(900);
        _execute(address(amm), bob, abi.encodeCall(amm.openMarket, (second)), _payload(BTC, OPEN, 900));
        uint256 liability = _buy(bob, second, false, 200e6, OPEN);
        _reject(
            address(amm),
            bob,
            abi.encodeCall(amm.resolveMarket, (0)),
            _payload(BTC, OPEN, 600),
            _reason("Invalid publish time")
        );
        assertEq(amm.lastSpotTimestamp(BTC), 900);
        assertGt(amm.reservedPayout(), liability);
        assertEq(amm.unresolvedExposureMarkets(), 2);
        vm.prank(lp);
        vm.expectRevert("Unresolved markets lock LPs");
        amm.withdraw(1e6, 0);
        assertEq(uint256(amm.getMarket(0).status), uint256(PredictionMarketAMMAtlas.Status.Trading));
        _execute(address(amm), bob, abi.encodeCall(amm.resolveMarket, (0)), _payload(BTC, OPEN, 900));
        assertEq(amm.reservedPayout(), liability);
        assertEq(amm.unresolvedExposureMarkets(), 1);
        assertEq(amm.getMarket(0).closingPrice, OPEN);
        assertEq(amm.boundaryPrices(BTC, 600), 0);
    }

    function testOpeningRequiresFreshQuoteWithoutExactTimestamp() public {
        uint256 id = amm.createMarket(0, 300, 10_000);
        vm.warp(906);
        _reject(
            address(amm),
            bob,
            abi.encodeCall(amm.openMarket, (id)),
            _payload(BTC, OPEN, 900),
            _reason("Invalid publish time")
        );
        assertEq(amm.boundaryPrices(BTC, 900), 0);
        assertEq(uint256(amm.getMarket(id).status), uint256(PredictionMarketAMMAtlas.Status.Scheduled));
        _execute(address(amm), bob, abi.encodeCall(amm.openMarket, (id)), _payload(BTC, OPEN, 901));
        assertEq(amm.getMarket(id).openingPrice, OPEN);
        assertEq(amm.getMarket(id).endTime, 1206);
        assertEq(amm.boundaryPrices(BTC, 901), 0);
    }

    function testResolutionAcceptsFreshQuoteAfterMissingExpiryWindow() public {
        _buy(alice, 0, true, 100e6, OPEN);
        vm.warp(606);
        _reject(
            address(amm),
            bob,
            abi.encodeCall(amm.resolveMarket, (0)),
            _payload(BTC, OPEN, 600),
            _reason("Invalid publish time")
        );
        assertEq(amm.boundaryPrices(BTC, 600), 0);
        assertEq(amm.unresolvedExposureMarkets(), 1);
        _execute(address(amm), bob, abi.encodeCall(amm.resolveMarket, (0)), _payload(BTC, OPEN, 601));
        assertEq(amm.unresolvedExposureMarkets(), 0);
        assertEq(amm.reservedPayout(), 0);
    }

    function testResolutionRejectsEarlyCallAndFreshPreExpiryQuote() public {
        _reject(
            address(amm),
            bob,
            abi.encodeCall(amm.resolveMarket, (0)),
            _payload(BTC, OPEN, 300),
            _reason("Not resolvable")
        );
        vm.warp(601);
        _reject(
            address(amm),
            bob,
            abi.encodeCall(amm.resolveMarket, (0)),
            _payload(BTC, OPEN, 599),
            _reason("Invalid publish time")
        );
        _resolve(0, OPEN, 601);
        _reject(
            address(amm),
            bob,
            abi.encodeCall(amm.resolveMarket, (0)),
            _payload(BTC, OPEN, 601),
            _reason("Not resolvable")
        );
    }

    function testBuyAcceptsExactlyFiveSecondOldPrice() public {
        vm.warp(305);
        _execute(
            address(amm),
            alice,
            abi.encodeCall(amm.buy, (0, true, 100e6, OPEN, 0, uint256(305))),
            _payload(BTC, OPEN, 300)
        );
        assertGt(amm.upBalance(0, alice), 0);
    }

    function testBuyRejectsStaleFutureAndMismatchedPrices() public {
        vm.warp(310);
        bytes memory callData = abi.encodeCall(amm.buy, (0, true, 100e6, OPEN, 0, block.timestamp));
        _reject(address(amm), alice, callData, _payload(BTC, OPEN, 304), _reason("Invalid publish time"));
        _reject(address(amm), alice, callData, _payload(BTC, OPEN, 311), _reason("Invalid oracle timestamp"));
        _reject(address(amm), alice, callData, _payload(BTC, 100.1e18, 310), _reason("Price mismatch"));
        assertEq(amm.upBalance(0, alice), 0);
    }

    function testExpiredDeadlineAndSlippageAreAtomic() public {
        _reject(
            address(amm),
            alice,
            abi.encodeCall(amm.buy, (0, true, 100e6, OPEN, 0, uint256(299))),
            _payload(BTC, OPEN, 300),
            _reason("Deadline passed")
        );
        _reject(
            address(amm),
            alice,
            abi.encodeCall(amm.buy, (0, true, 100e6, OPEN, 195e6, uint256(300))),
            _payload(BTC, OPEN, 300),
            _reason("Share slippage")
        );
        assertEq(amm.reservedPayout(), 0);
    }

    function testPauseCutoffAndWorkerResolution() public {
        _buy(alice, 0, true, 100e6, OPEN);
        amm.setTradingPaused(true);
        _reject(
            address(amm),
            bob,
            abi.encodeCall(amm.buy, (0, false, 100e6, OPEN, 0, block.timestamp)),
            _payload(BTC, OPEN, block.timestamp),
            _reason("Trading paused")
        );
        amm.setTradingPaused(false);
        vm.warp(595);
        _reject(
            address(amm),
            bob,
            abi.encodeCall(amm.buy, (0, false, 100e6, OPEN, 0, block.timestamp)),
            _payload(BTC, OPEN, block.timestamp),
            _reason("Market closed")
        );
        amm.setTradingPaused(true);
        _resolve(0, OPEN, 600);
        assertEq(uint256(amm.getMarket(0).status), uint256(PredictionMarketAMMAtlas.Status.Resolved));
    }

    function testBlockedWinnerRevertsWholeResolutionAndCanRetry() public {
        uint256 first = _buy(alice, 0, true, 100e6, OPEN);
        uint256 second = _buy(bob, 0, true, 100e6, OPEN);
        usdc.setBlocked(bob);
        vm.warp(600);
        _reject(
            address(amm),
            bob,
            abi.encodeCall(amm.resolveMarket, (0)),
            _payload(BTC, OPEN, 600),
            _reason("Recipient blocked")
        );
        assertEq(amm.upBalance(0, alice), first);
        assertEq(amm.upBalance(0, bob), second);
        assertEq(amm.reservedPayout(), first + second);
        assertEq(amm.boundaryPrices(BTC, 600), 0);
        usdc.setBlocked(address(0));
        _execute(address(amm), bob, abi.encodeCall(amm.resolveMarket, (0)), _payload(BTC, OPEN, 600));
        assertEq(amm.reservedPayout(), 0);
    }

    function testTransferFeeBuyAndSettlementReentryAreRejected() public {
        usdc.setChargeFee(true);
        _reject(
            address(amm),
            alice,
            abi.encodeCall(amm.buy, (0, true, 100e6, OPEN, 0, block.timestamp)),
            _payload(BTC, OPEN, block.timestamp),
            _reason("Unsupported transfer fee")
        );
        assertEq(amm.reservedPayout(), 0);
        usdc.setChargeFee(false);
        _buy(alice, 0, true, 100e6, OPEN);
        usdc.setReentry(address(amm), abi.encodeCall(amm.resolveMarket, (0)));
        _resolve(0, OPEN, 600);
        assertFalse(usdc.reentrySucceeded());
        assertEq(amm.reservedPayout(), 0);
    }

    function testRemovedPairKeepsOriginalFeedForOutstandingRound() public {
        _buy(alice, 0, true, 100e6, OPEN);
        amm.removePair(0);
        assertEq(amm.addPair("BTC_USD", ETH), 1);
        _resolve(0, OPEN, 600);
        assertEq(amm.atlasFeedIds(0), BTC);
        assertEq(amm.getMarket(0).closingPrice, OPEN);
    }

    function testWorkerAuthorizationAndRoundValidation() public {
        vm.prank(alice);
        vm.expectRevert();
        amm.authorizeBackend(alice, true);
        vm.expectRevert("Invalid backend");
        amm.authorizeBackend(address(0), true);
        vm.expectRevert("Invalid duration");
        amm.createMarket(0, 301, 10_000);
        vm.expectRevert("Invalid volatility");
        amm.createMarket(0, 300, 99);
        vm.expectRevert("Invalid volatility");
        amm.createMarket(0, 300, 50_001);
        vm.prank(alice);
        vm.expectRevert("Not authorized backend");
        amm.createMarket(0, 300, 10_000);
        vm.prank(bob);
        uint256 id = amm.createMarket(0, 300, 10_000);
        amm.createMarket(0, 300, 10_000);
        vm.warp(931);
        _reject(
            address(amm),
            alice,
            abi.encodeCall(amm.openMarket, (id)),
            _payload(BTC, OPEN, 931),
            _reason("Not authorized backend")
        );
        _execute(address(amm), bob, abi.encodeCall(amm.openMarket, (id)), _payload(BTC, OPEN, 931));
        amm.authorizeBackend(bob, false);
        vm.warp(1231);
        _reject(
            address(amm),
            bob,
            abi.encodeCall(amm.resolveMarket, (id)),
            _payload(BTC, OPEN, 1231),
            _reason("Not authorized backend")
        );
        _execute(address(amm), address(this), abi.encodeCall(amm.resolveMarket, (id)), _payload(BTC, OPEN, 1231));
    }

    function testFuzzOddsAndQuotesMatchOriginal(uint64 priceSeed, bool up) public {
        vm.warp(1);
        AtlasParityPyth oracle = new AtlasParityPyth();
        PredictionMarketAMM original = PredictionMarketAMM(
            deployCode(
                "PredictionMarketAMM.sol:PredictionMarketAMM", abi.encode(address(usdc), address(oracle), uint256(300))
            )
        );
        original.addPair("BTC_USD", bytes32(uint256(1)));
        original.createMarket(0, 300, 10_000);
        vm.warp(300);
        original.openMarket(0, new bytes[](0));
        uint256 spot = bound(uint256(priceSeed), 99.9e18, 100.1e18);
        assertEq(amm.winProbability(0, up, spot), original.winProbability(0, up, spot));
        (uint256 payout, uint256 fee) = amm.quoteBuy(0, up, 100e6, spot);
        (uint256 oldPayout, uint256 oldFee) = original.quoteBuy(0, up, 100e6, spot);
        assertEq(payout, oldPayout);
        assertEq(fee, oldFee);
    }

    function testNoNativeUpdateFeeAndRuntimeFitsEip170() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(amm).call{value: 1}(
            bytes.concat(
                abi.encodeCall(amm.buy, (0, true, 100e6, OPEN, 0, block.timestamp)),
                _payload(BTC, OPEN, block.timestamp)
            )
        );
        assertFalse(ok);
        assertLe(address(amm).code.length, 24_576);
    }

    function _fund(address account, uint256 assets) internal {
        usdc.ownerMint(account, assets);
        vm.prank(account);
        usdc.approve(address(amm), type(uint256).max);
    }

    function _buy(address account, uint256 id, bool up, uint256 assets, uint256 spot)
        internal
        returns (uint256 payout)
    {
        (payout,) = amm.quoteBuy(id, up, assets, spot);
        bytes memory result = _execute(
            address(amm),
            account,
            abi.encodeCall(amm.buy, (id, up, assets, spot, payout, block.timestamp)),
            _payload(BTC, spot, block.timestamp)
        );
        assertEq(abi.decode(result, (uint256)), payout);
    }

    function _resolve(uint256 id, uint256 price, uint256 end) internal {
        vm.warp(end);
        _execute(address(amm), bob, abi.encodeCall(amm.resolveMarket, (id)), _payload(BTC, price, end));
    }
}
