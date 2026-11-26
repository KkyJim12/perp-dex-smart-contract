// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TradingAccount7702} from "../src/TradingAccount7702.sol";
import {DeployTradingAccount7702} from "../script/DeployTradingAccount7702.s.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {PerpDex} from "../src/PerpDex.sol";
import {ppUSDC} from "../src/ppUSDC.sol";
import {PredictionMarketAMM} from "../src/PredictionMarketAMM.sol";
import {OptionAMM} from "../src/OptionAMM.sol";
import {opUSDC} from "../src/opUSDC.sol";
import {PythStructs} from "lib/pyth-sdk-solidity/PythStructs.sol";

contract Account7702Target {
    address public lastSender;
    uint256 public lastValue;
    uint256 public count;
    bool public reentrySucceeded;

    function record() external payable returns (uint256) {
        lastSender = msg.sender;
        lastValue = msg.value;
        return ++count;
    }

    function fail() external pure {
        revert("Target failed");
    }

    function reenter(address account, bytes calldata data) external {
        (reentrySucceeded,) = account.call(data);
    }
}

contract Account7702Oracle {
    uint256 public constant FEE = 1e12;
    PythStructs.Price private price;

    function setPrice(int64 value) external {
        price = PythStructs.Price(value, 0, 0, block.timestamp);
    }

    function getUpdateFee(bytes[] calldata) external pure returns (uint256) {
        return FEE;
    }

    function updatePriceFeeds(bytes[] calldata) external payable {
        require(msg.value == FEE, "Oracle fee");
    }

    function getPrice(bytes32) external view returns (PythStructs.Price memory) {
        return price;
    }

    function getPriceUnsafe(bytes32) external view returns (PythStructs.Price memory) {
        return price;
    }

    function getPriceNoOlderThan(bytes32, uint256) external view returns (PythStructs.Price memory) {
        return price;
    }

    function parsePriceFeedUpdatesUnique(bytes[] calldata, bytes32[] calldata ids, uint64, uint64)
        external
        payable
        returns (PythStructs.PriceFeed[] memory feeds)
    {
        require(msg.value == FEE, "Oracle fee");
        feeds = new PythStructs.PriceFeed[](1);
        feeds[0] = PythStructs.PriceFeed(ids[0], price, price);
    }
}

contract TradingAccount7702Test is Test {
    uint256 private constant KEY = 0x7702;
    address private owner;
    address private sponsor;
    TradingAccount7702 private implementation;
    TradingAccount7702 private account;
    Account7702Target private target;
    uint256 private deadline;

    function setUp() public {
        vm.warp(300);
        owner = vm.addr(KEY);
        sponsor = makeAddr("sponsor");
        implementation = new TradingAccount7702();
        vm.signAndAttachDelegation(address(implementation), KEY);
        account = TradingAccount7702(payable(owner));
        target = new Account7702Target();
        deadline = block.timestamp + 1 hours;
        vm.deal(owner, 1 ether);
        vm.deal(sponsor, 1 ether);
    }

    function _calls() private view returns (TradingAccount7702.Call[] memory calls) {
        calls = new TradingAccount7702.Call[](1);
        calls[0] = TradingAccount7702.Call(address(target), 0, 200_000, abi.encodeCall(target.record, ()));
    }

    function _sign(TradingAccount7702.Call[] memory calls, uint256 n, uint256 expires, address relayer, uint256 funding)
        private
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, account.batchDigest(calls, n, expires, relayer, funding));
        return abi.encodePacked(r, s, v);
    }

    function _submit(TradingAccount7702.Call[] memory calls, bytes memory signature) private {
        vm.prank(sponsor);
        account.executeSigned(calls, 0, deadline, sponsor, signature);
    }

    function testRealDelegationSelfExecutionPreservesEOA() public {
        assertEq(owner.code, abi.encodePacked(hex"ef0100", address(implementation)));
        TradingAccount7702.Call[] memory calls = _calls();
        vm.prank(owner);
        bytes[] memory results = account.execute(calls);
        assertEq(abi.decode(results[0], (uint256)), 1);
        assertEq(target.lastSender(), owner);
        assertEq(account.nonce(), 1);
        assertEq(implementation.nonce(), 0);
    }

    function testSponsoredExecutionAndReplayProtection() public {
        TradingAccount7702.Call[] memory calls = _calls();
        bytes memory signature = _sign(calls, 0, deadline, sponsor, 0);
        _submit(calls, signature);
        assertEq(target.lastSender(), owner);
        vm.expectRevert(abi.encodeWithSelector(TradingAccount7702.InvalidNonce.selector, 1, 0));
        _submit(calls, signature);
        assertEq(target.count(), 1);
    }

    function testStandardEIP712SignatureFromCastExecutes() public {
        // Independent typed-data signature from fixtures/batch.json, produced by:
        // cast wallet sign --data --from-file test7702/fixtures/batch.json
        //   --private-key 0x0000000000000000000000000000000000000000000000000000000000007702
        vm.chainId(31337);
        vm.prank(address(0x123456));
        TradingAccount7702 vectorImplementation = new TradingAccount7702();
        assertEq(address(vectorImplementation), 0x2413D83cD1BFb45eB033e656fb5C98B04838Dd19);
        vm.signAndAttachDelegation(address(vectorImplementation), KEY);
        vm.prank(owner);
        account.invalidateNonce(7);
        TradingAccount7702.Call[] memory calls = new TradingAccount7702.Call[](2);
        calls[0] = TradingAccount7702.Call(address(0x1111), 1, 100_000, hex"abcd01");
        calls[1] = TradingAccount7702.Call(address(0x2222), 2, 100_000, "");
        vm.deal(address(0x3333), 3);
        vm.prank(address(0x3333));
        account.executeSigned{value: 3}(
            calls,
            7,
            3600,
            address(0x3333),
            hex"65beb2a11e0ae9d5c950fc160853ff64b6a265324937b3bdee479168f7f788582899fbbfa0648e7259f3d5ea6acccbfb2c8c3b88f8706d32e1ad3c65370d5b131c"
        );
        assertEq(account.nonce(), 8);
        assertEq(address(0x1111).balance, 1);
        assertEq(address(0x2222).balance, 2);
    }

    function testUnauthorizedSelfExecutionAndCancellation() public {
        vm.prank(sponsor);
        vm.expectRevert(TradingAccount7702.Unauthorized.selector);
        account.execute(_calls());
        vm.prank(sponsor);
        vm.expectRevert(TradingAccount7702.Unauthorized.selector);
        account.invalidateNonce(5);
    }

    function testDirectImplementationCannotExecute() public {
        vm.expectRevert(TradingAccount7702.NotDelegated.selector);
        implementation.execute(_calls());
        vm.expectRevert(TradingAccount7702.NotDelegated.selector);
        implementation.executeSigned(_calls(), 0, deadline, sponsor, "");
        vm.expectRevert(TradingAccount7702.NotDelegated.selector);
        implementation.invalidateNonce(1);
    }

    function testCancellationAndSelfExecutionInvalidatePendingSignatures() public {
        TradingAccount7702.Call[] memory calls = _calls();
        bytes memory signature = _sign(calls, 0, deadline, sponsor, 0);
        vm.prank(owner);
        account.invalidateNonce(10);
        vm.expectRevert(abi.encodeWithSelector(TradingAccount7702.InvalidNonce.selector, 10, 0));
        _submit(calls, signature);
        signature = _sign(calls, 10, deadline, sponsor, 0);
        vm.prank(owner);
        account.execute(calls);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(TradingAccount7702.InvalidNonce.selector, 11, 10));
        account.executeSigned(calls, 10, deadline, sponsor, signature);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TradingAccount7702.InvalidNonce.selector, 12, 11));
        account.invalidateNonce(11);
    }

    function testExpiredAndWrongRelayerRejected() public {
        TradingAccount7702.Call[] memory calls = _calls();
        bytes memory signature = _sign(calls, 0, deadline, sponsor, 0);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(TradingAccount7702.Unauthorized.selector);
        account.executeSigned(calls, 0, deadline, sponsor, signature);
        vm.warp(deadline + 1);
        vm.expectRevert(TradingAccount7702.Expired.selector);
        _submit(calls, signature);
    }

    function testOpenRelayerAndExactDeadline() public {
        TradingAccount7702.Call[] memory calls = _calls();
        bytes memory signature = _sign(calls, 0, deadline, address(0), 0);
        vm.warp(deadline);
        vm.prank(sponsor);
        account.executeSigned(calls, 0, deadline, address(0), signature);
        assertEq(target.lastSender(), owner);
    }

    function testMalformedAndWrongSignerRejected() public {
        TradingAccount7702.Call[] memory calls = _calls();
        vm.expectRevert(TradingAccount7702.InvalidSignature.selector);
        _submit(calls, hex"1234");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(123, account.batchDigest(calls, 0, deadline, sponsor, 0));
        vm.expectRevert(TradingAccount7702.InvalidSignature.selector);
        _submit(calls, abi.encodePacked(r, s, v));
    }

    function testFuzzEverySignedCallFieldIsBound(uint8 field, uint256 changed) public {
        field = uint8(bound(field, 0, 5));
        changed = bound(changed, 1, 1e18);
        TradingAccount7702.Call[] memory calls = _calls();
        bytes memory signature = _sign(calls, 0, deadline, sponsor, 0);
        if (field == 0) calls[0].target = address(0x1234);
        if (field == 1) calls[0].value = changed;
        if (field == 2) calls[0].gasLimit += changed;
        if (field == 3) calls[0].data = abi.encodeCall(target.fail, ());
        if (field == 4) deadline += changed;
        if (field == 5) {
            TradingAccount7702.Call[] memory extended = new TradingAccount7702.Call[](2);
            extended[0] = calls[0];
            extended[1] = calls[0];
            calls = extended;
        }
        vm.expectRevert(TradingAccount7702.InvalidSignature.selector);
        _submit(calls, signature);
        assertEq(account.nonce(), 0);
    }

    function testFundingAndRelayerAreSigned() public {
        TradingAccount7702.Call[] memory calls = _calls();
        bytes memory signature = _sign(calls, 0, deadline, sponsor, 1);
        vm.expectRevert(TradingAccount7702.InvalidSignature.selector);
        _submit(calls, signature);
        signature = _sign(calls, 0, deadline, sponsor, 0);
        vm.prank(sponsor);
        vm.expectRevert(TradingAccount7702.InvalidSignature.selector);
        account.executeSigned(calls, 0, deadline, address(0), signature);
    }

    function testChainAccountAndImplementationDomainsAreBound() public {
        TradingAccount7702.Call[] memory calls = _calls();
        bytes memory signature = _sign(calls, 0, deadline, sponsor, 0);
        uint256 chain = block.chainid;
        vm.chainId(chain + 1);
        vm.expectRevert(TradingAccount7702.InvalidSignature.selector);
        _submit(calls, signature);
        vm.chainId(chain);
        address otherOwner = vm.addr(KEY + 1);
        vm.signAndAttachDelegation(address(implementation), KEY + 1);
        vm.prank(sponsor);
        vm.expectRevert(TradingAccount7702.InvalidSignature.selector);
        TradingAccount7702(payable(otherOwner)).executeSigned(calls, 0, deadline, sponsor, signature);
        TradingAccount7702 otherImplementation = new TradingAccount7702();
        vm.signAndAttachDelegation(address(otherImplementation), KEY);
        vm.expectRevert(TradingAccount7702.InvalidSignature.selector);
        _submit(calls, signature);
    }

    function testDelegationReplacementPreservesNonceAndCancellation() public {
        vm.prank(owner);
        account.invalidateNonce(10);
        TradingAccount7702 replacement = new TradingAccount7702();
        vm.signAndAttachDelegation(address(replacement), KEY);
        assertEq(account.nonce(), 10);
        vm.prank(owner);
        account.execute(_calls());
        assertEq(account.nonce(), 11);
    }

    function testRejectedBatchRollsBackApprovalsAndNonce() public {
        MockUSDC usdc = new MockUSDC();
        TradingAccount7702.Call[] memory calls = new TradingAccount7702.Call[](2);
        calls[0] =
            TradingAccount7702.Call(address(usdc), 0, 200_000, abi.encodeCall(usdc.approve, (address(target), 100e6)));
        calls[1] = TradingAccount7702.Call(address(target), 0, 200_000, abi.encodeCall(target.fail, ()));
        bytes memory signature = _sign(calls, 0, deadline, sponsor, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                TradingAccount7702.CallFailed.selector, 1, abi.encodeWithSignature("Error(string)", "Target failed")
            )
        );
        _submit(calls, signature);
        assertEq(usdc.allowance(owner, address(target)), 0);
        assertEq(account.nonce(), 0);
    }

    function testReentrancyCannotExecuteAnotherValidSignedBatch() public {
        TradingAccount7702.Call[] memory nested = _calls();
        bytes memory nestedSignature = _sign(nested, 1, deadline, address(0), 0);
        TradingAccount7702.Call[] memory calls = _calls();
        calls[0].data = abi.encodeCall(
            target.reenter,
            (owner, abi.encodeCall(account.executeSigned, (nested, 1, deadline, address(0), nestedSignature)))
        );
        _submit(calls, _sign(calls, 0, deadline, sponsor, 0));
        assertFalse(target.reentrySucceeded());
        assertEq(target.count(), 0);
        assertEq(account.nonce(), 1);
    }

    function testEmptyAndInvalidCallsRejected() public {
        vm.prank(owner);
        vm.expectRevert(TradingAccount7702.EmptyBatch.selector);
        account.execute(new TradingAccount7702.Call[](0));
        TradingAccount7702.Call[] memory calls = _calls();
        calls[0].target = owner;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TradingAccount7702.InvalidCall.selector, 0));
        account.execute(calls);
        calls[0].target = address(0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TradingAccount7702.InvalidCall.selector, 0));
        account.execute(calls);
        calls[0].target = address(target);
        calls[0].gasLimit = 0;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TradingAccount7702.InvalidCall.selector, 0));
        account.execute(calls);
        assertEq(account.nonce(), 0);
    }

    function testInsufficientOuterGasCannotConsumeNonce() public {
        TradingAccount7702.Call[] memory calls = _calls();
        bytes memory signature = _sign(calls, 0, deadline, sponsor, 0);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(TradingAccount7702.InsufficientExecutionGas.selector, 0));
        account.executeSigned{gas: 150_000}(calls, 0, deadline, sponsor, signature);
        assertEq(account.nonce(), 0);
    }

    function testNativeFundsFromSponsorAndExistingAccountBalance() public {
        TradingAccount7702.Call[] memory calls = _calls();
        calls[0].value = 0.25 ether;
        bytes memory signature = _sign(calls, 0, deadline, sponsor, 0.1 ether);
        vm.prank(sponsor);
        account.executeSigned{value: 0.1 ether}(calls, 0, deadline, sponsor, signature);
        assertEq(target.lastValue(), 0.25 ether);
        assertEq(owner.balance, 0.85 ether);
        assertEq(sponsor.balance, 0.9 ether);
        assertEq(address(implementation).balance, 0);
    }

    function testDeploymentScriptDeploysUninitializedImplementation() public {
        vm.setEnv("PRIVATE_KEY", "30500");
        DeployTradingAccount7702 script = new DeployTradingAccount7702();
        address deployed = script.run();
        assertGt(deployed.code.length, 0);
        assertEq(TradingAccount7702(payable(deployed)).IMPLEMENTATION(), deployed);
        assertEq(TradingAccount7702(payable(deployed)).nonce(), 0);
    }
}

contract TradingAccount7702MarketsTest is Test {
    uint256 private constant KEY = 0xA7702;
    uint256 private constant FEE = 1e12;
    address private owner;
    address private sponsor;
    TradingAccount7702 private account;
    MockUSDC private usdc;
    PerpDex private perp;
    OptionAMM private option;
    PredictionMarketAMM private prediction;
    Account7702Oracle private oracle;

    function setUp() public {
        vm.warp(300);
        vm.deal(address(this), 1 ether);
        owner = vm.addr(KEY);
        sponsor = makeAddr("market sponsor");
        vm.deal(sponsor, 1 ether);
        vm.signAndAttachDelegation(address(new TradingAccount7702()), KEY);
        account = TradingAccount7702(payable(owner));
        usdc = new MockUSDC();
        oracle = new Account7702Oracle();
        oracle.setPrice(100);
        ppUSDC perpShares = new ppUSDC();
        perp = new PerpDex(address(usdc), address(oracle), address(perpShares));
        perpShares.setMinter(address(perp), true);
        perp.addPair("BTC_USD", bytes32(uint256(1)), 20, 50_000e6, 2, 100, 5e18);
        opUSDC optionShares = new opUSDC();
        option = new OptionAMM(address(usdc), address(oracle), address(optionShares));
        optionShares.setOptionAMM(address(option));
        option.addPair("BTC_USD", bytes32(uint256(1)));
        prediction = new PredictionMarketAMM(address(usdc), address(oracle), 300);
        prediction.addPair("BTC_USD", bytes32(uint256(1)));
        usdc.ownerMint(address(this), 300_000e6);
        usdc.approve(address(perp), 100_000e6);
        perp.depositLP(100_000e6);
        usdc.approve(address(option), 100_000e6);
        option.deposit(100_000e6, option.previewDeposit(100_000e6));
        usdc.approve(address(prediction), 100_000e6);
        prediction.deposit(100_000e6, 100_000e6);
        vm.warp(1 days - 1);
        option.createMarket(0, 1 days, 1 days, 100e18, 10_000, 300, true);
        prediction.createMarket(0, 300, 10_000);
        vm.warp(1 days);
        oracle.setPrice(100);
        option.openMarket{value: FEE}(0, new bytes[](0));
        prediction.openMarket{value: FEE}(0, new bytes[](0));
        usdc.ownerMint(owner, 5_000e6);
    }

    function _tradeCalls() private view returns (TradingAccount7702.Call[] memory calls) {
        calls = new TradingAccount7702.Call[](6);
        calls[0] =
            TradingAccount7702.Call(address(usdc), 0, 100_000, abi.encodeCall(usdc.approve, (address(perp), 100e6)));
        calls[1] = TradingAccount7702.Call(
            address(perp),
            FEE,
            2_000_000,
            abi.encodeCall(perp.openPosition, ("BTC_USD", true, 100e6, 10, new bytes[](0), 0, 0))
        );
        calls[2] = TradingAccount7702.Call(
            address(usdc), 0, 100_000, abi.encodeCall(usdc.approve, (address(prediction), 100e6))
        );
        calls[3] = TradingAccount7702.Call(
            address(prediction),
            FEE,
            1_000_000,
            abi.encodeCall(prediction.buy, (0, true, 100e6, 100e18, 194e6, block.timestamp, new bytes[](0)))
        );
        (uint256 premium,) = option.quoteBuy(0, 1_000e6, 100e18);
        calls[4] = TradingAccount7702.Call(
            address(usdc), 0, 100_000, abi.encodeCall(usdc.approve, (address(option), premium))
        );
        calls[5] = TradingAccount7702.Call(
            address(option),
            FEE,
            1_000_000,
            abi.encodeCall(option.buy, (0, 1_000e6, 100e18, premium, block.timestamp, new bytes[](0)))
        );
    }

    function _sponsoredTrade(TradingAccount7702.Call[] memory calls) private {
        uint256 expires = block.timestamp + 300;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, account.batchDigest(calls, 0, expires, sponsor, 3 * FEE));
        vm.prank(sponsor);
        account.executeSigned{value: 3 * FEE}(calls, 0, expires, sponsor, abi.encodePacked(r, s, v));
    }

    function _assertTrades() private view {
        (bytes32 id,,, uint256 margin,,,,,,,,,,,,) = perp.positions(owner, 0);
        assertTrue(id != bytes32(0));
        assertEq(margin, 100e6);
        assertEq(prediction.upBalance(0, owner), 194e6);
        (uint256 premium,) = option.quoteBuy(0, 1_000e6, 100e18);
        assertEq(option.optionBalance(0, owner), 1_000e6);
        assertEq(usdc.balanceOf(owner), 4_800e6 - premium);
        assertEq(usdc.balanceOf(sponsor), 0);
        assertEq(account.nonce(), 1);
        assertEq(usdc.allowance(owner, address(perp)), 0);
        assertEq(usdc.allowance(owner, address(prediction)), 0);
        assertEq(usdc.allowance(owner, address(option)), 0);
    }

    function testSponsoredAtomicTradingAcrossAllThreeMarkets() public {
        assertEq(owner.balance, 0);
        _sponsoredTrade(_tradeCalls());
        _assertTrades();
        assertEq(owner.balance, 0);
    }

    function testSelfFundedAtomicTradingAcrossAllThreeMarkets() public {
        vm.deal(owner, 3 * FEE);
        TradingAccount7702.Call[] memory calls = _tradeCalls();
        vm.prank(owner);
        account.execute(calls);
        _assertTrades();
        assertEq(owner.balance, 0);
    }

    function testOneRejectedTradeRollsBackAllThreeMarkets() public {
        TradingAccount7702.Call[] memory calls = _tradeCalls();
        (uint256 premium,) = option.quoteBuy(0, 1_000e6, 100e18);
        calls[5].data = abi.encodeCall(option.buy, (0, 1_000e6, 100e18, premium - 1, block.timestamp, new bytes[](0)));
        uint256 expires = block.timestamp + 300;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, account.batchDigest(calls, 0, expires, sponsor, 3 * FEE));
        vm.expectRevert(
            abi.encodeWithSelector(
                TradingAccount7702.CallFailed.selector,
                5,
                abi.encodeWithSignature("Error(string)", "Premium exceeds limit")
            )
        );
        vm.prank(sponsor);
        account.executeSigned{value: 3 * FEE}(calls, 0, expires, sponsor, abi.encodePacked(r, s, v));
        assertEq(perp.totalOpenMargin(), 0);
        assertEq(prediction.upBalance(0, owner), 0);
        assertEq(option.reservedPayout(), 0);
        assertEq(usdc.balanceOf(owner), 5_000e6);
        assertEq(account.nonce(), 0);
        assertEq(usdc.allowance(owner, address(perp)), 0);
    }

    function testSettlementPaysOriginalEOAAndPerpCanCloseThroughDelegation() public {
        (uint256 premium,) = option.quoteBuy(0, 1_000e6, 100e18);
        _sponsoredTrade(_tradeCalls());
        vm.warp(2 days);
        oracle.setPrice(150);
        prediction.resolveMarket{value: FEE}(0, new bytes[](0));
        option.finalizeMarket{value: FEE}(0, new bytes[](0));
        assertEq(usdc.balanceOf(owner), 5_494e6 - premium);
        (bytes32 id,,,,,,,,,,,,,,,) = perp.positions(owner, 0);
        TradingAccount7702.Call[] memory calls = new TradingAccount7702.Call[](1);
        calls[0] = TradingAccount7702.Call(
            address(perp), FEE, 2_000_000, abi.encodeCall(perp.closePosition, (id, new bytes[](0)))
        );
        vm.deal(owner, FEE);
        vm.prank(owner);
        account.execute(calls);
        (,,,,,,,, bool closed,,,,,,,) = perp.positions(owner, 0);
        assertTrue(closed);
        assertEq(account.nonce(), 2);
        assertGt(usdc.balanceOf(owner), 5_494e6 - premium);
    }

    function testDelegatedPartialOptionSalePaysOriginalEOA() public {
        _sponsoredTrade(_tradeCalls());
        (uint256 proceeds,) = option.quoteSell(0, 500e6, 100e18);
        uint256 balance = usdc.balanceOf(owner);
        TradingAccount7702.Call[] memory calls = new TradingAccount7702.Call[](1);
        calls[0] = TradingAccount7702.Call(
            address(option),
            FEE,
            1_000_000,
            abi.encodeCall(option.sell, (0, 500e6, 100e18, proceeds, block.timestamp, new bytes[](0)))
        );
        vm.deal(owner, FEE);
        vm.prank(owner);
        account.execute(calls);
        assertEq(option.optionBalance(0, owner), 500e6);
        assertEq(usdc.balanceOf(owner), balance + proceeds);
        assertEq(account.nonce(), 2);
    }
}
