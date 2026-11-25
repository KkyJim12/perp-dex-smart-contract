// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PythStructs} from "pyth-sdk-solidity/PythStructs.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {OptionAMM} from "../src/OptionAMM.sol";
import {opUSDC} from "../src/opUSDC.sol";

contract OptionMockPyth {
    struct Update {
        bytes32 id;
        PythStructs.Price price;
        uint256 previousTime;
    }
    mapping(bytes32 => PythStructs.Price) public prices;

    function getUpdateFee(bytes[] calldata data) external pure returns (uint256) {
        return data.length;
    }

    function updatePriceFeeds(bytes[] calldata data) external payable {
        require(msg.value == data.length, "Oracle fee");
        for (uint256 i; i < data.length; ++i) {
            Update memory u = abi.decode(data[i], (Update));
            if (u.price.publishTime > prices[u.id].publishTime) prices[u.id] = u.price;
        }
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythStructs.Price memory p) {
        p = prices[id];
        require(p.publishTime <= block.timestamp && block.timestamp - p.publishTime <= age, "Stale price");
    }

    function parsePriceFeedUpdatesUnique(bytes[] calldata data, bytes32[] calldata ids, uint64 minTime, uint64 maxTime)
        external
        payable
        returns (PythStructs.PriceFeed[] memory feeds)
    {
        require(msg.value == data.length && ids.length == 1, "Oracle inputs");
        feeds = new PythStructs.PriceFeed[](1);
        for (uint256 i; i < data.length; ++i) {
            Update memory u = abi.decode(data[i], (Update));
            if (
                u.id == ids[0] && u.previousTime < minTime && u.price.publishTime >= minTime
                    && u.price.publishTime <= maxTime
            ) {
                feeds[0] = PythStructs.PriceFeed(u.id, u.price, u.price);
                return feeds;
            }
        }
        revert("Boundary unavailable");
    }
}

contract OptionTransferMock is MockUSDC {
    address public blockedRecipient;
    bool public chargeFee;
    bool public falseReturn;
    address public reentryTarget;
    bool public reentrySucceeded;

    function setBlocked(address recipient) external {
        blockedRecipient = recipient;
    }

    function setChargeFee(bool value) external {
        chargeFee = value;
    }

    function setFalseReturn(bool value) external {
        falseReturn = value;
    }

    function setReentry(address target) external {
        reentryTarget = target;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to != blockedRecipient, "Recipient blocked");
        if (reentryTarget != address(0)) {
            (reentrySucceeded,) = reentryTarget.call(abi.encodeWithSignature("claim()"));
        }
        bool ok = super.transfer(to, amount);
        return falseReturn ? false : ok;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        if (chargeFee) _burn(to, 1);
        return ok;
    }
}

contract OptionAMMTest is Test {
    OptionTransferMock usdc;
    opUSDC shares;
    OptionAMM amm;
    OptionMockPyth pyth;
    address lp = makeAddr("lp");
    address buyer = makeAddr("buyer");
    address bob = makeAddr("bob");
    address backend = makeAddr("backend");
    bytes32 constant BTC = bytes32(uint256(1));
    uint256 constant OPEN = 100e18;
    uint256 constant NOTIONAL = 1_000e6;
    uint64 constant DURATION = 1 days;
    uint64 constant START = 1 days;
    uint64 constant END = START + DURATION;

    function setUp() public {
        vm.warp(1);
        vm.deal(address(this), 100 ether);
        vm.deal(backend, 1 ether);
        usdc = new OptionTransferMock();
        shares = new opUSDC();
        pyth = new OptionMockPyth();
        amm = new OptionAMM(address(usdc), address(pyth), address(shares));
        shares.setOptionAMM(address(amm));
        amm.authorizeBackend(backend, true);
        amm.addPair("BTC", BTC);
        usdc.ownerMint(lp, 10_000e6);
        _fund(buyer);
        _fund(bob);
        vm.prank(lp);
        usdc.approve(address(amm), type(uint256).max);
        vm.prank(lp);
        amm.deposit(10_000e6, 10_000e6 * 1e6);
    }

    function _fund(address account) internal {
        usdc.ownerMint(account, 20_000e6);
        vm.deal(account, 1 ether);
        vm.prank(account);
        usdc.approve(address(amm), type(uint256).max);
    }

    function _data(uint256 value, uint256 time, uint256 previousTime) internal pure returns (bytes[] memory data) {
        data = new bytes[](1);
        data[0] =
            abi.encode(OptionMockPyth.Update(BTC, PythStructs.Price(int64(int256(value)), 0, -8, time), previousTime));
    }

    function _market(bool isCall) internal returns (uint256 id) {
        vm.prank(backend);
        id = amm.createMarket(0, DURATION, START, OPEN, 10_000, 300, isCall);
        vm.warp(START);
        bytes[] memory data = _data(100e8, START, START - 1);
        vm.prank(backend);
        amm.openMarket{value: 1}(id, data);
    }

    function _buy(uint256 id, address account, uint256 contracts, uint256 spot) internal returns (uint256 premium) {
        (premium,) = amm.quoteBuy(id, contracts, spot * 1e10);
        bytes[] memory data = _data(spot, block.timestamp, block.timestamp - 1);
        vm.prank(account);
        assertEq(amm.buy{value: 1}(id, contracts, spot * 1e10, premium, block.timestamp, data), premium);
    }

    function _sell(uint256 id, address account, uint256 contracts, uint256 spot) internal returns (uint256 proceeds) {
        (proceeds,) = amm.quoteSell(id, contracts, spot * 1e10);
        bytes[] memory data = _data(spot, block.timestamp, block.timestamp - 1);
        vm.prank(account);
        assertEq(amm.sell{value: 1}(id, contracts, spot * 1e10, proceeds, block.timestamp, data), proceeds);
    }

    function _finalize(uint256 id, uint256 spot) internal {
        OptionAMM.Market memory m = amm.getMarket(id);
        vm.warp(m.endTime);
        bytes[] memory data = _data(spot, m.endTime, m.endTime - 1);
        vm.prank(backend);
        amm.finalizeMarket{value: 1}(id, data);
    }

    function testBackendLifecycleAndAutomaticPayouts() public {
        uint256 id = _market(true);
        uint256 premium = _buy(id, buyer, NOTIONAL, 100e8);
        assertEq(amm.optionBalance(id, buyer), NOTIONAL);
        assertEq(amm.reservedPayout(), NOTIONAL);
        assertEq(amm.vaultValue(), 9_000e6 + premium);
        _finalize(id, 150e8);
        assertEq(usdc.balanceOf(buyer), 20_000e6 - premium + 500e6);
        assertEq(amm.optionBalance(id, buyer), 0);
        assertEq(amm.reservedPayout(), 0);
        assertEq(amm.vaultPayouts(), 500e6);
        assertEq(uint256(amm.getMarket(id).status), uint256(OptionAMM.Status.Finalized));
        assertEq(amm.getMarket(id).closingPrice, 150e18);
    }

    function testPutPaysIntrinsicAndCallCapsAtNotional() public {
        uint256 id = _market(false);
        uint256 premium = _buy(id, buyer, NOTIONAL, 100e8);
        _finalize(id, 50e8);
        assertEq(usdc.balanceOf(buyer), 20_000e6 - premium + 500e6);
    }

    function testCallPayoutCannotExceedReservedNotional() public {
        uint256 id = _market(true);
        _buy(id, buyer, NOTIONAL, 100e8);
        _finalize(id, 500e8);
        assertEq(amm.vaultPayouts(), NOTIONAL);
        assertEq(amm.reservedPayout(), 0);
    }

    function testSellPartialThenFullReleasesCollateralAndDoesNotDuplicateTrader() public {
        uint256 id = _market(true);
        uint256 premium = _buy(id, buyer, NOTIONAL, 100e8);
        uint256 a = _sell(id, buyer, 400e6, 100e8);
        assertEq(amm.optionBalance(id, buyer), 600e6);
        assertEq(amm.reservedPayout(), 600e6);
        assertEq(amm.unresolvedExposureMarkets(), 1);
        uint256 b = _sell(id, buyer, 600e6, 100e8);
        assertEq(amm.reservedPayout(), 0);
        assertEq(amm.unresolvedExposureMarkets(), 0);
        assertLe(a + b, premium);
        _buy(id, buyer, NOTIONAL, 100e8);
        assertEq(amm.traderCount(id), 1);
        assertEq(amm.unresolvedExposureMarkets(), 1);
        assertEq(amm.vaultSaleProceeds(), a + b);
    }

    function testSoldOptionAreNotPaidAgain() public {
        uint256 id = _market(true);
        _buy(id, buyer, NOTIONAL, 100e8);
        _sell(id, buyer, NOTIONAL, 100e8);
        uint256 balance = usdc.balanceOf(buyer);
        _finalize(id, 200e8);
        assertEq(usdc.balanceOf(buyer), balance);
        assertEq(amm.vaultPayouts(), 0);
    }

    function testCannotSellAnotherUsersOptionOrOversell() public {
        uint256 id = _market(true);
        _buy(id, buyer, NOTIONAL, 100e8);
        bytes[] memory data = _data(100e8, START, START - 1);
        vm.prank(bob);
        vm.expectRevert("Invalid contracts");
        amm.sell{value: 1}(id, NOTIONAL, OPEN, 0, START, data);
        vm.prank(buyer);
        vm.expectRevert("Invalid contracts");
        amm.sell{value: 1}(id, NOTIONAL + 1e6, OPEN, 0, START, data);
        vm.prank(buyer);
        vm.expectRevert("Dust remainder");
        amm.sell{value: 1}(id, NOTIONAL - 1, OPEN, 0, START, data);
    }

    function testPremiumRespondsToSpotAndTimeAndAvoidsDeepITMDiscount() public {
        uint256 id = _market(true);
        uint256 early = amm.optionValue(id, OPEN);
        assertGt(amm.optionValue(id, 101e18), early);
        vm.warp(END - 6);
        assertLt(amm.optionValue(id, OPEN), early);
        (uint256 premium,) = amm.quoteBuy(id, 8_000e6, 200e18);
        assertGe(premium, 8_000e6 - 10); // Former fixed quote was only 800 USDC.
    }

    function testUnauthorizedCannotScheduleOpenOrFinalizeAndRevocationWorks() public {
        vm.prank(buyer);
        vm.expectRevert("Not authorized backend");
        amm.createMarket(0, DURATION, START, OPEN, 10_000, 300, true);
        uint256 id = _market(true);
        vm.warp(END);
        bytes[] memory data = _data(150e8, END, END - 1);
        vm.prank(buyer);
        vm.expectRevert("Not authorized backend");
        amm.finalizeMarket{value: 1}(id, data);
        amm.authorizeBackend(backend, false);
        vm.prank(backend);
        vm.expectRevert("Not authorized backend");
        amm.finalizeMarket{value: 1}(id, data);
        amm.finalizeMarket{value: 1}(id, data); // Owner recovery.
    }

    function testAllSupportedDurationsThroughSettlement() public {
        uint64[5] memory durations = [uint64(1 days), 3 days, 7 days, 14 days, 30 days];
        for (uint256 i; i < durations.length; ++i) {
            for (uint256 direction; direction < 2; ++direction) {
                uint64 duration = durations[i];
                uint64 start = uint64((block.timestamp / duration + 1) * duration);
                bool isCall = direction == 0;
                vm.expectRevert("Invalid start");
                amm.createMarket(0, duration, start + 1, OPEN, 10_000, 300, isCall);
                uint256 id = amm.createMarket(0, duration, start, OPEN, 10_000, 300, isCall);
                OptionAMM.Market memory m = amm.getMarket(id);
                assertEq(m.startTime, start);
                assertEq(m.endTime, start + duration);
                vm.warp(start);
                amm.openMarket{value: 1}(id, _data(100e8, start, start - 1));
                uint256 premium = _buy(id, buyer, NOTIONAL, 100e8);
                uint256 balance = usdc.balanceOf(buyer);
                assertGt(premium, 0);
                _finalize(id, isCall ? 150e8 : 50e8);
                assertEq(usdc.balanceOf(buyer), balance + 500e6);
                assertEq(uint256(amm.getMarket(id).status), uint256(OptionAMM.Status.Finalized));
                assertEq(amm.reservedPayout(), 0);
            }
        }
    }

    function testShortAndUnsupportedDurationsRejected() public {
        uint64[7] memory durations = [uint64(0), 5 minutes, 15 minutes, 1 hours, 2 days, 5 days, 31 days];
        for (uint256 i; i < durations.length; ++i) {
            vm.expectRevert("Invalid duration");
            amm.createMarket(0, durations[i], 31 days, OPEN, 10_000, 300, true);
        }
    }

    function testMarketValidationATMAndMissedOpeningCancellation() public {
        vm.expectRevert("Invalid duration");
        amm.createMarket(0, 301, 301, OPEN, 10_000, 300, true);
        vm.expectRevert("Invalid start");
        amm.createMarket(0, DURATION, START + 1, OPEN, 10_000, 300, true);
        vm.expectRevert("Invalid volatility");
        amm.createMarket(0, DURATION, START, OPEN, 99, 300, true);
        vm.expectRevert("Fee exceeds 5%");
        amm.createMarket(0, DURATION, START, OPEN, 10_000, 501, true);
        uint256 id = amm.createMarket(0, DURATION, START, 0, 10_000, 300, true);
        vm.expectRevert("Round exists");
        amm.createMarket(0, DURATION, START, 0, 10_000, 300, true);
        vm.warp(START);
        amm.openMarket{value: 1}(id, _data(100e8, START, START - 1));
        assertEq(amm.getMarket(id).strikePrice, OPEN);
        amm.cancelMarket(id);
        assertEq(uint256(amm.getMarket(id).status), uint256(OptionAMM.Status.Cancelled));
    }

    function testPairRemovalDoesNotChangeExistingMarkets() public {
        uint256 id = _market(true);
        _buy(id, buyer, NOTIONAL, 100e8);
        amm.removePair(0);
        vm.expectRevert("Pair inactive");
        amm.createMarket(0, DURATION, END, OPEN, 10_000, 300, true);
        _finalize(id, 150e8);
        assertEq(amm.pairCount(), 1);
    }

    function testBoundaryHistoricalPriceIgnoresNewerSpotCacheAndRejectsNonUniqueUpdate() public {
        uint256 id = _market(true);
        _buy(id, buyer, NOTIONAL, 100e8);
        vm.warp(END + 60);
        pyth.updatePriceFeeds{value: 1}(_data(200e8, END + 60, END + 59));
        bytes[] memory late = _data(200e8, END + 10, END + 9);
        vm.expectRevert("Boundary unavailable");
        amm.finalizeMarket{value: 1}(id, late);
        amm.finalizeMarket{value: 1}(id, _data(100e8, END, END - 1));
        assertEq(amm.vaultPayouts(), 0);
        assertEq(amm.getMarket(id).closingPrice, OPEN);
        vm.expectRevert("Not finalizable");
        amm.finalizeMarket{value: 1}(id, _data(200e8, END, END - 1));
    }

    function testBuyAndSellSlippageDeadlineAndPriceMismatch() public {
        uint256 id = _market(true);
        (uint256 premium,) = amm.quoteBuy(id, NOTIONAL, OPEN);
        bytes[] memory data = _data(100e8, START, START - 1);
        vm.prank(buyer);
        vm.expectRevert("Premium exceeds limit");
        amm.buy{value: 1}(id, NOTIONAL, OPEN, premium - 1, START, data);
        _buy(id, buyer, NOTIONAL, 100e8);
        (uint256 proceeds,) = amm.quoteSell(id, NOTIONAL, OPEN);
        vm.prank(buyer);
        vm.expectRevert("Proceeds below limit");
        amm.sell{value: 1}(id, NOTIONAL, OPEN, proceeds + 1, START, data);
        vm.prank(buyer);
        vm.expectRevert("Deadline passed");
        amm.sell{value: 1}(id, NOTIONAL, OPEN, 0, START - 1, data);
        vm.prank(buyer);
        vm.expectRevert("Price mismatch");
        amm.buy{value: 1}(id, NOTIONAL, 101e18, type(uint256).max, START, data);
    }

    function testStaleFutureUncertainAndWrongExponentPricesRejected() public {
        uint256 id = _market(true);
        vm.warp(START + 10);
        bytes[] memory data = _data(100e8, START, START - 1);
        vm.prank(buyer);
        vm.expectRevert("Stale price");
        amm.buy{value: 1}(id, NOTIONAL, OPEN, type(uint256).max, START + 10, data);
        data = _data(100e8, START + 11, START + 10);
        vm.prank(buyer);
        vm.expectRevert("Stale price");
        amm.buy{value: 1}(id, NOTIONAL, OPEN, type(uint256).max, START + 10, data);
        data[0] = abi.encode(OptionMockPyth.Update(BTC, PythStructs.Price(100e8, 2e8, -8, START + 10), START + 9));
        vm.prank(buyer);
        vm.expectRevert("Uncertain price");
        amm.buy{value: 1}(id, NOTIONAL, OPEN, type(uint256).max, START + 10, data);
        data[0] = abi.encode(OptionMockPyth.Update(BTC, PythStructs.Price(100e8, 0, -19, START + 10), START + 9));
        vm.prank(buyer);
        vm.expectRevert("Invalid price");
        amm.buy{value: 1}(id, NOTIONAL, OPEN, type(uint256).max, START + 10, data);
        data = _data(100e8, START + 10, START + 9);
        vm.prank(buyer);
        vm.expectRevert("Incorrect Pyth fee");
        amm.buy(id, NOTIONAL, OPEN, type(uint256).max, START + 10, data);
    }

    function testCutoffPauseAndFinalizationWhilePaused() public {
        uint256 id = _market(true);
        _buy(id, buyer, NOTIONAL, 100e8);
        amm.setTradingPaused(true);
        vm.expectRevert("Trading paused");
        amm.quoteSell(id, NOTIONAL, OPEN);
        amm.setTradingPaused(false);
        vm.warp(END - 5);
        vm.expectRevert("Market closed");
        amm.quoteBuy(id, NOTIONAL, OPEN);
        amm.setTradingPaused(true);
        _finalize(id, 150e8);
        assertEq(amm.reservedPayout(), 0);
    }

    function testUtilizationFailureRollsBackFundsAndExposure() public {
        uint256 id = _market(true);
        uint256 balance = usdc.balanceOf(buyer);
        bytes[] memory data = _data(100e8, START, START - 1);
        vm.prank(buyer);
        vm.expectRevert("Vault utilization exceeded");
        amm.buy{value: 1}(id, 9_000e6, OPEN, type(uint256).max, START, data);
        assertEq(usdc.balanceOf(buyer), balance);
        assertEq(amm.reservedPayout(), 0);
        assertEq(amm.traderCount(id), 0);
        assertEq(amm.unresolvedExposureMarkets(), 0);
    }

    function testLPWithdrawalQueuePreventsPerpetualNewExposureAndAllowsSales() public {
        uint256 id = _market(true);
        _buy(id, buyer, NOTIONAL, 100e8);
        uint256 lpShares = shares.balanceOf(lp);
        vm.prank(lp);
        shares.approve(address(amm), lpShares);
        vm.prank(lp);
        amm.requestWithdrawal(lpShares);
        bytes[] memory data = _data(100e8, START, START - 1);
        vm.prank(bob);
        vm.expectRevert("LP withdrawals pending");
        amm.buy{value: 1}(id, NOTIONAL, OPEN, type(uint256).max, START, data);
        vm.expectRevert("Unresolved markets lock LPs");
        amm.executeWithdrawal(lp);
        _sell(id, buyer, NOTIONAL, 100e8);
        uint256 assets = amm.executeWithdrawal(lp);
        assertGt(assets, 10_000e6);
        assertEq(amm.queuedWithdrawalShares(), 0);
        assertEq(shares.totalSupply(), 0);
        assertEq(usdc.balanceOf(lp), assets);
    }

    function testQueueCanBeCancelledAndBlockedLPDoesNotHaltTrading() public {
        uint256 lpShares = shares.balanceOf(lp);
        vm.startPrank(lp);
        shares.approve(address(amm), type(uint256).max);
        amm.requestWithdrawal(lpShares);
        amm.cancelWithdrawal();
        assertEq(shares.balanceOf(lp), lpShares);
        amm.requestWithdrawal(lpShares);
        vm.stopPrank();
        usdc.setBlocked(lp);
        uint256 assets = amm.executeWithdrawal(lp);
        assertEq(amm.claimable(lp), assets);
        assertEq(amm.queuedWithdrawalShares(), 0);
        assertEq(amm.totalClaimable(), assets);
        assertLe(amm.vaultValue(), 1);
    }

    function testDustSharesCannotHaltTradingWithWithdrawalQueue() public {
        vm.prank(lp);
        shares.transfer(buyer, 1);
        vm.prank(buyer);
        shares.approve(address(amm), 1);
        vm.prank(buyer);
        vm.expectRevert("Withdrawal too small");
        amm.requestWithdrawal(1);
        assertEq(amm.queuedWithdrawalShares(), 0);
    }

    function testBlockedBuyerDoesNotBlockOthersAndClaimsRemainFundedAfterLPExit() public {
        uint256 id = _market(true);
        uint256 a = _buy(id, buyer, NOTIONAL, 100e8);
        uint256 b = _buy(id, bob, NOTIONAL, 100e8);
        usdc.setBlocked(buyer);
        _finalize(id, 150e8);
        assertEq(amm.claimable(buyer), 500e6);
        assertEq(amm.totalClaimable(), 500e6);
        assertEq(usdc.balanceOf(bob), 20_000e6 - b + 500e6);
        assertEq(usdc.balanceOf(buyer), 20_000e6 - a);
        uint256 lpShares = shares.balanceOf(lp);
        vm.prank(lp);
        amm.withdraw(lpShares, 0);
        assertGe(usdc.balanceOf(address(amm)), 500e6);
        usdc.setBlocked(address(0));
        vm.prank(buyer);
        assertEq(amm.claim(), 500e6);
        assertEq(amm.totalClaimable(), 0);
        vm.prank(buyer);
        vm.expectRevert("Nothing to claim");
        amm.claim();
    }

    function testFalseReturningTransferIsRolledBackAndReentryCannotClaim() public {
        uint256 id = _market(true);
        _buy(id, buyer, NOTIONAL, 100e8);
        uint256 balance = usdc.balanceOf(buyer);
        usdc.setFalseReturn(true);
        _finalize(id, 150e8);
        assertEq(usdc.balanceOf(buyer), balance);
        assertEq(amm.claimable(buyer), 500e6);
        usdc.setFalseReturn(false);
        usdc.setReentry(address(amm));
        vm.prank(buyer);
        amm.claim();
        assertFalse(usdc.reentrySucceeded());
        vm.expectRevert("Only self");
        amm.paySettlement(buyer, 1);
    }

    function testDonationAttackAndDepositSlippageAreProtected() public {
        uint256 lpShares = shares.balanceOf(lp);
        vm.prank(lp);
        amm.withdraw(lpShares, 0);
        vm.prank(bob);
        amm.deposit(1, 0);
        vm.prank(bob);
        usdc.transfer(address(amm), 500e6);
        uint256 victimShares = amm.previewDeposit(1_000e6);
        vm.prank(buyer);
        vm.expectRevert("Share slippage");
        amm.deposit(1_000e6, victimShares + 1);
        vm.prank(buyer);
        amm.deposit(1_000e6, victimShares);
        uint256 attackerShares = shares.balanceOf(bob);
        vm.prank(bob);
        uint256 recovered = amm.withdraw(attackerShares, 0);
        assertLt(recovered, 500e6); // Donation is unprofitable, rather than extracting 250 USDC.
        assertGe(amm.previewRedeem(victimShares), 1_000e6 - 1_000);
    }

    function testFeeOnTransferDepositAndBuyRevertAtomically() public {
        usdc.setChargeFee(true);
        vm.prank(buyer);
        vm.expectRevert("Unsupported transfer fee");
        amm.deposit(100e6, 0);
        uint256 id = _market(true);
        bytes[] memory data = _data(100e8, START, START - 1);
        vm.prank(buyer);
        vm.expectRevert("Unsupported transfer fee");
        amm.buy{value: 1}(id, NOTIONAL, OPEN, type(uint256).max, START, data);
        assertEq(amm.reservedPayout(), 0);
    }

    function testParticipantBoundAndAutomaticPaymentAtMaximumCapacity() public {
        uint256 id = _market(true);
        for (uint256 i; i < 128; ++i) {
            address holder = address(uint160(10_000 + i));
            _fund(holder);
            _buy(id, holder, 1e6, 100e8);
        }
        assertEq(amm.traderCount(id), 128);
        _sell(id, address(uint160(10_000)), 1e6, 100e8);
        _buy(id, address(uint160(10_000)), 1e6, 100e8);
        assertEq(amm.traderCount(id), 128);
        bytes[] memory data = _data(100e8, START, START - 1);
        vm.prank(buyer);
        vm.expectRevert("Market participant limit");
        amm.buy{value: 1}(id, 1e6, OPEN, type(uint256).max, START, data);
        _finalize(id, 150e8);
        assertEq(amm.vaultPayouts(), 64e6);
        assertEq(amm.totalClaimable(), 0);
        assertEq(amm.reservedPayout(), 0);
    }

    function testFuzzQuoteBoundsAndSpread(uint256 spot, uint256 notional, bool isCall) public {
        uint256 id = _market(isCall);
        spot = bound(spot, 1e18, 300e18);
        notional = bound(notional, 1e6, 1_000_000e6);
        uint256 value = amm.optionValue(id, spot);
        assertLe(value, 1e18);
        (uint256 proceeds,) = amm.quoteSell(id, notional, spot);
        assertLe(proceeds, notional);
        if (value > 0) {
            (uint256 premium,) = amm.quoteBuy(id, notional, spot);
            assertLe(proceeds, premium);
            assertLe(premium, notional + (notional * 300 + 9_999) / 10_000 + 1);
        }
    }
}
