// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OptionAMMAtlas} from "../src/OptionAMMAtlas.sol";
import {OptionAMM} from "../src/OptionAMM.sol";
import {opUSDC} from "../src/opUSDC.sol";
import {AtlasSignedTest} from "./helpers/AtlasSignedTest.sol";
import {AtlasTransferMock} from "./helpers/AtlasTransferMock.sol";
import {AtlasParityPyth} from "./helpers/AtlasParityPyth.sol";

contract OptionAMMAtlasTest is AtlasSignedTest {
    OptionAMMAtlas amm;
    AtlasTransferMock usdc;
    opUSDC shares;
    address lp = makeAddr("atlas-option-lp");
    address buyer = makeAddr("atlas-option-buyer");
    address bob = makeAddr("atlas-option-bob");
    address backend = makeAddr("atlas-option-backend");
    uint64 constant START = 1 days;
    uint64 constant END = 2 days;
    uint256 constant OPEN = 100e18;
    uint256 constant NOTIONAL = 1_000e6;

    function setUp() public {
        vm.warp(1);
        usdc = AtlasTransferMock(deployCode("AtlasTransferMock.sol:AtlasTransferMock"));
        shares = opUSDC(deployCode("opUSDC.sol:opUSDC"));
        amm = OptionAMMAtlas(
            deployCode(
                "OptionAMMAtlas.sol:OptionAMMAtlas", abi.encode(address(usdc), vm.addr(ATLAS_KEY), address(shares))
            )
        );
        shares.setOptionAMM(address(amm));
        amm.authorizeBackend(backend, true);
        amm.addPair("BTC", BTC);
        _fund(lp, 10_000e6);
        _fund(buyer, 20_000e6);
        _fund(bob, 20_000e6);
        uint256 minShares = amm.previewDeposit(10_000e6);
        vm.prank(lp);
        amm.deposit(10_000e6, minShares);
    }

    function testBackendLifecycleAndDelayedHistoricalSettlement() public {
        uint256 id = _market(true);
        uint256 premium = _buy(id, buyer, NOTIONAL, OPEN);
        assertEq(amm.reservedPayout(), NOTIONAL);
        assertEq(amm.vaultValue(), 9_000e6 + premium);
        vm.warp(END + 7 days);
        _execute(address(amm), backend, abi.encodeCall(amm.finalizeMarket, (id)), _payload(BTC, 150e18, END));
        assertEq(usdc.balanceOf(buyer), 20_000e6 - premium + 500e6);
        assertEq(amm.vaultPayouts(), 500e6);
        assertEq(amm.reservedPayout(), 0);
        assertEq(amm.unresolvedExposureMarkets(), 0);
        assertEq(amm.optionBalance(id, buyer), 0);
        assertEq(uint256(amm.getMarket(id).status), uint256(OptionAMMAtlas.Status.Finalized));
    }

    function testFuzzCallAndPutSettlementPreservesCappedPayoff(bool isCall, uint96 priceSeed) public {
        uint256 closingPrice = bound(uint256(priceSeed), 1e18, 500e18);
        uint256 id = _market(isCall);
        uint256 premium = _buy(id, buyer, NOTIONAL, OPEN);
        uint256 difference =
            isCall ? (closingPrice > OPEN ? closingPrice - OPEN : 0) : (closingPrice < OPEN ? OPEN - closingPrice : 0);
        uint256 payout = NOTIONAL * (difference > OPEN ? OPEN : difference) / OPEN;
        _finalize(id, closingPrice);
        assertEq(usdc.balanceOf(buyer), 20_000e6 - premium + payout);
        assertEq(amm.vaultPayouts(), payout);
        assertLe(payout, NOTIONAL);
    }

    function testPartialAndFullSaleReleaseReserves() public {
        uint256 id = _market(true);
        uint256 premium = _buy(id, buyer, NOTIONAL, OPEN);
        uint256 first = _sell(id, buyer, 400e6);
        assertEq(amm.reservedPayout(), 600e6);
        uint256 second = _sell(id, buyer, 600e6);
        assertEq(amm.reservedPayout(), 0);
        assertEq(amm.unresolvedExposureMarkets(), 0);
        assertEq(amm.traderCount(id), 1);
        assertEq(usdc.balanceOf(buyer), 20_000e6 - premium + first + second);
        _finalize(id, 150e18);
        assertEq(amm.vaultPayouts(), 0);
    }

    function testBuyAndSellUseFreshMatchingSpot() public {
        uint256 id = _market(true);
        _buy(id, buyer, NOTIONAL, OPEN);
        vm.warp(START + 10);
        bytes memory buyCall = abi.encodeCall(amm.buy, (id, NOTIONAL, OPEN, type(uint256).max, block.timestamp));
        bytes memory sellCall = abi.encodeCall(amm.sell, (id, NOTIONAL, OPEN, 0, block.timestamp));
        bytes memory stale = _payload(BTC, OPEN, START);
        _reject(address(amm), bob, buyCall, stale, _reason("Invalid publish time"));
        _reject(address(amm), buyer, sellCall, stale, _reason("Invalid publish time"));
        bytes memory wrongPrice = _payload(BTC, 101e18, block.timestamp);
        _reject(address(amm), bob, buyCall, wrongPrice, _reason("Price mismatch"));
        _reject(address(amm), buyer, sellCall, wrongPrice, _reason("Price mismatch"));
    }

    function testBoundaryQuotesMustMatchScheduledSecond() public {
        uint256 id = amm.createMarket(0, 1 days, START, 0, 10_000, 300, true);
        vm.warp(START + 1);
        _reject(
            address(amm),
            backend,
            abi.encodeCall(amm.openMarket, (id)),
            _payload(BTC, OPEN, START + 1),
            _reason("Wrong boundary timestamp")
        );
        _execute(address(amm), backend, abi.encodeCall(amm.openMarket, (id)), _payload(BTC, OPEN, START));
        assertEq(amm.getMarket(id).strikePrice, OPEN);
        vm.warp(END + 1);
        _reject(
            address(amm),
            backend,
            abi.encodeCall(amm.finalizeMarket, (id)),
            _payload(BTC, 150e18, END + 1),
            _reason("Wrong boundary timestamp")
        );
        _execute(address(amm), backend, abi.encodeCall(amm.finalizeMarket, (id)), _payload(BTC, 150e18, END));
    }

    function testAuthorizationAndRevocationStillApply() public {
        uint256 id = amm.createMarket(0, 1 days, START, OPEN, 10_000, 300, true);
        vm.warp(START);
        _reject(
            address(amm),
            buyer,
            abi.encodeCall(amm.openMarket, (id)),
            _payload(BTC, OPEN, START),
            _reason("Not authorized backend")
        );
        _execute(address(amm), backend, abi.encodeCall(amm.openMarket, (id)), _payload(BTC, OPEN, START));
        amm.authorizeBackend(backend, false);
        vm.warp(END);
        _reject(
            address(amm),
            backend,
            abi.encodeCall(amm.finalizeMarket, (id)),
            _payload(BTC, OPEN, END),
            _reason("Not authorized backend")
        );
        _execute(address(amm), address(this), abi.encodeCall(amm.finalizeMarket, (id)), _payload(BTC, OPEN, END));
    }

    function testOpeningWindowAndTradingCutoffPreserved() public {
        uint256 missed = amm.createMarket(0, 1 days, START, 0, 10_000, 300, true);
        uint256 id = amm.createMarket(0, 1 days, START, OPEN, 10_000, 300, true);
        vm.warp(START);
        _execute(address(amm), backend, abi.encodeCall(amm.openMarket, (id)), _payload(BTC, OPEN, START));
        vm.warp(START + 31);
        _reject(
            address(amm),
            backend,
            abi.encodeCall(amm.openMarket, (missed)),
            _payload(BTC, OPEN, START),
            _reason("Opening window closed")
        );
        amm.cancelMarket(missed);
        vm.warp(END - 5);
        _reject(
            address(amm),
            buyer,
            abi.encodeCall(amm.buy, (id, NOTIONAL, OPEN, type(uint256).max, block.timestamp)),
            _payload(BTC, OPEN, block.timestamp),
            _reason("Market closed")
        );
    }

    function testBlockedWinnerGetsDeferredClaimWhileOthersArePaid() public {
        uint256 id = _market(true);
        _buy(id, buyer, NOTIONAL, OPEN);
        uint256 bobPremium = _buy(id, bob, NOTIONAL, OPEN);
        usdc.setBlocked(buyer);
        _finalize(id, 150e18);
        assertEq(amm.claimable(buyer), 500e6);
        assertEq(usdc.balanceOf(bob), 20_000e6 - bobPremium + 500e6);
        uint256 lpShares = shares.balanceOf(lp);
        vm.prank(lp);
        amm.withdraw(lpShares, 0);
        assertGe(usdc.balanceOf(address(amm)), 500e6);
        usdc.setBlocked(address(0));
        vm.prank(buyer);
        assertEq(amm.claim(), 500e6);
        assertEq(amm.totalClaimable(), 0);
    }

    function testFalseReturningTransferAndClaimReentryCannotSteal() public {
        uint256 id = _market(true);
        _buy(id, buyer, NOTIONAL, OPEN);
        usdc.setFalseReturn(true);
        _finalize(id, 150e18);
        assertEq(amm.claimable(buyer), 500e6);
        usdc.setFalseReturn(false);
        usdc.setReentry(address(amm), abi.encodeCall(amm.claim, ()));
        vm.prank(buyer);
        amm.claim();
        assertFalse(usdc.reentrySucceeded());
        assertEq(amm.totalClaimable(), 0);
    }

    function testWithdrawalQueueBlocksNewBuysAndExecutesAfterExposureEnds() public {
        uint256 id = _market(true);
        _buy(id, buyer, NOTIONAL, OPEN);
        vm.startPrank(lp);
        shares.approve(address(amm), type(uint256).max);
        amm.requestWithdrawal(shares.balanceOf(lp));
        vm.stopPrank();
        _reject(
            address(amm),
            bob,
            abi.encodeCall(amm.buy, (id, NOTIONAL, OPEN, type(uint256).max, block.timestamp)),
            _payload(BTC, OPEN, block.timestamp),
            _reason("LP withdrawals pending")
        );
        _sell(id, buyer, NOTIONAL);
        assertGt(amm.executeWithdrawal(lp), 10_000e6);
        assertEq(amm.queuedWithdrawalShares(), 0);
    }

    function testTransferFeeBuyRevertsAndRestoresAllExposure() public {
        uint256 id = _market(true);
        usdc.setChargeFee(true);
        _reject(
            address(amm),
            buyer,
            abi.encodeCall(amm.buy, (id, NOTIONAL, OPEN, type(uint256).max, block.timestamp)),
            _payload(BTC, OPEN, block.timestamp),
            _reason("Unsupported transfer fee")
        );
        assertEq(amm.reservedPayout(), 0);
        assertEq(amm.optionBalance(id, buyer), 0);
        assertEq(amm.traderCount(id), 0);
    }

    function testRemovedPairStillSettlesOriginalFeedAndStableId() public {
        uint256 id = _market(true);
        _buy(id, buyer, NOTIONAL, OPEN);
        amm.removePair(0);
        assertEq(amm.addPair("BTC", ETH), 1);
        assertEq(amm.atlasFeedIds(0), BTC);
        _finalize(id, 150e18);
        assertEq(amm.getMarket(id).closingPrice, 150e18);
    }

    function testFuzzQuotesMatchOriginalPricing(bool isCall, uint64 priceSeed) public {
        opUSDC originalShares = opUSDC(deployCode("opUSDC.sol:opUSDC"));
        AtlasParityPyth oracle = new AtlasParityPyth();
        OptionAMM original = OptionAMM(
            deployCode("OptionAMM.sol:OptionAMM", abi.encode(address(usdc), address(oracle), address(originalShares)))
        );
        original.addPair("BTC", bytes32(uint256(1)));
        uint256 originalId = original.createMarket(0, 1 days, START, OPEN, 10_000, 300, isCall);
        uint256 id = _market(isCall);
        original.openMarket(originalId, new bytes[](0));
        uint256 spot = bound(uint256(priceSeed), 95e18, 105e18);
        assertEq(amm.optionValue(id, spot), original.optionValue(originalId, spot));
        (uint256 premium, uint256 fee) = amm.quoteBuy(id, NOTIONAL, spot);
        (uint256 oldPremium, uint256 oldFee) = original.quoteBuy(originalId, NOTIONAL, spot);
        assertEq(premium, oldPremium);
        assertEq(fee, oldFee);
        (uint256 proceeds, uint256 saleFee) = amm.quoteSell(id, NOTIONAL, spot);
        (uint256 oldProceeds, uint256 oldSaleFee) = original.quoteSell(originalId, NOTIONAL, spot);
        assertEq(proceeds, oldProceeds);
        assertEq(saleFee, oldSaleFee);
    }

    function testNoNativeUpdateFeeAndRuntimeFitsEip170() public {
        uint256 id = amm.createMarket(0, 1 days, START, OPEN, 10_000, 300, true);
        vm.warp(START);
        vm.deal(backend, 1 ether);
        vm.prank(backend);
        (bool ok,) =
            address(amm).call{value: 1}(bytes.concat(abi.encodeCall(amm.openMarket, (id)), _payload(BTC, OPEN, START)));
        assertFalse(ok);
        assertLe(address(amm).code.length, 24_576);
    }

    function _fund(address account, uint256 assets) internal {
        usdc.ownerMint(account, assets);
        vm.prank(account);
        usdc.approve(address(amm), type(uint256).max);
    }

    function _market(bool isCall) internal returns (uint256 id) {
        id = amm.createMarket(0, 1 days, START, OPEN, 10_000, 300, isCall);
        vm.warp(START);
        _execute(address(amm), backend, abi.encodeCall(amm.openMarket, (id)), _payload(BTC, OPEN, START));
    }

    function _buy(uint256 id, address account, uint256 contracts, uint256 spot) internal returns (uint256 premium) {
        (premium,) = amm.quoteBuy(id, contracts, spot);
        bytes memory result = _execute(
            address(amm),
            account,
            abi.encodeCall(amm.buy, (id, contracts, spot, premium, block.timestamp)),
            _payload(BTC, spot, block.timestamp)
        );
        assertEq(abi.decode(result, (uint256)), premium);
    }

    function _sell(uint256 id, address account, uint256 contracts) internal returns (uint256 proceeds) {
        (proceeds,) = amm.quoteSell(id, contracts, OPEN);
        _execute(
            address(amm),
            account,
            abi.encodeCall(amm.sell, (id, contracts, OPEN, proceeds, block.timestamp)),
            _payload(BTC, OPEN, block.timestamp)
        );
    }

    function _finalize(uint256 id, uint256 price) internal {
        vm.warp(END);
        _execute(address(amm), backend, abi.encodeCall(amm.finalizeMarket, (id)), _payload(BTC, price, END));
    }
}
