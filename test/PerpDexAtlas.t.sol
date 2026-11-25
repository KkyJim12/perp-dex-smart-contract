// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IPullOracleBase} from "lib/pull-oracle-consumer/src/interfaces/IPullOracleBase.sol";
import {PerpDexAtlas} from "../src/PerpDexAtlas.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {ppUSDC} from "../src/ppUSDC.sol";

/// @dev Exercise the production SDK with real ECDSA signatures, without mocking verification.
contract PerpDexAtlasTest is Test {
    uint256 internal constant SIGNER_KEY = 0xa71a5;
    uint256 internal constant OTHER_KEY = 0xbad;
    bytes4 internal constant BTC = 0x00000001; // Test IDs, not a production feed registry.
    bytes4 internal constant ETH = 0x00000002;
    uint256 internal constant ENTRY = 50_000e8;
    uint256 internal constant MARGIN = 100e6;
    address internal trader = makeAddr("atlas-trader");
    MockUSDC internal usdc;
    ppUSDC internal shares;
    PerpDexAtlas internal dex;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        shares = new ppUSDC();
        dex = new PerpDexAtlas(address(usdc), address(shares), vm.addr(SIGNER_KEY), 60);
        shares.setMinter(address(dex), true);
        dex.addPair("BTC_USD", BTC, 20, 50_000e6, 2, 100, 5e18);
        usdc.ownerMint(address(this), 100_000e6);
        usdc.approve(address(dex), type(uint256).max);
        dex.depositLP(100_000e6);
        usdc.ownerMint(trader, 1_000e6);
        vm.prank(trader);
        usdc.approve(address(dex), type(uint256).max);
    }

    function testInitialPoolAndEmptyConstructor() public {
        assertEq(shares.balanceOf(address(this)), 100_000e6);
        assertEq(dex.getppUSDCPrice(), 1e18);
        PerpDexAtlas empty = new PerpDexAtlas(address(usdc), address(shares), vm.addr(SIGNER_KEY), 60);
        assertEq(empty.totalLiquidityRatio(), 0);
        assertEq(empty.atlasSigner(), vm.addr(SIGNER_KEY));
        assertEq(empty.maxPriceAge(), 60);
        assertEq(empty.PRICE_DECIMALS(), 8);
    }

    function testConstructorRejectsInvalidConfiguration() public {
        vm.expectRevert("Invalid address");
        new PerpDexAtlas(address(0), address(shares), vm.addr(SIGNER_KEY), 60);
        vm.expectRevert("Invalid address");
        new PerpDexAtlas(address(usdc), address(0), vm.addr(SIGNER_KEY), 60);
        vm.expectRevert("Invalid address");
        new PerpDexAtlas(address(usdc), address(shares), address(0), 60);
        vm.expectRevert("Invalid max price age");
        new PerpDexAtlas(address(usdc), address(shares), vm.addr(SIGNER_KEY), 0);
    }

    function testCannotRegisterZeroFeed() public {
        vm.expectRevert("Invalid feed ID");
        dex.addPair("BAD", bytes4(0), 1, 1e6, 1, 2, 5e18);
    }

    function testOpenNormalizes18DecimalsAndDefaultsTP() public {
        _open(true);
        PerpDexAtlas.Position memory p = _position(0);
        assertEq(p.entryPrice, ENTRY);
        assertEq(p.takeProfit, 75_000e8);
        assertEq(p.atlasFeedId, BTC);
        assertEq(p.margin, MARGIN);
        assertEq(dex.lastPriceTimestamp(BTC), block.timestamp);
    }

    function testOpenRejectsMissingPayload() public {
        _reject(trader, _openCall(true), "", abi.encodeWithSelector(IPullOracleBase.InvalidMarker.selector));
    }

    function testRejectsUnauthorizedSignature() public {
        _reject(
            trader,
            _openCall(true),
            _payload(OTHER_KEY, BTC, ENTRY * 1e10, block.timestamp),
            abi.encodeWithSelector(IPullOracleBase.UnauthorizedSigner.selector, vm.addr(OTHER_KEY))
        );
    }

    function testTamperedSignedPriceCannotOpen() public {
        bytes memory payload = _payload(SIGNER_KEY, BTC, ENTRY * 1e10, block.timestamp);
        payload[4] = bytes1(uint8(payload[4]) ^ 1);
        vm.prank(trader);
        (bool ok,) = address(dex).call(bytes.concat(_openCall(true), payload));
        assertFalse(ok);
        assertEq(dex.totalOpenMargin(), 0);
    }

    function testRejectsWrongFeed() public {
        _reject(
            trader,
            _openCall(true),
            _payload(SIGNER_KEY, ETH, ENTRY * 1e10, block.timestamp),
            abi.encodeWithSelector(IPullOracleBase.UnmatchedFeedID.selector, BTC)
        );
    }

    function testRejectsExpiredPrice() public {
        _reject(
            trader,
            _openCall(true),
            _payload(SIGNER_KEY, BTC, ENTRY * 1e10, block.timestamp - 61),
            _reason("Stale oracle price")
        );
    }

    function testRejectsFutureAndZeroTimestamp() public {
        _reject(
            trader,
            _openCall(true),
            _payload(SIGNER_KEY, BTC, ENTRY * 1e10, block.timestamp + 1),
            _reason("Invalid oracle timestamp")
        );
        _reject(
            trader, _openCall(true), _payload(SIGNER_KEY, BTC, ENTRY * 1e10, 0), _reason("Invalid oracle timestamp")
        );
    }

    function testAcceptsExactFreshnessBoundary() public {
        _execute(trader, _openCall(true), _payload(SIGNER_KEY, BTC, ENTRY * 1e10, block.timestamp - 60));
        assertEq(_position(0).entryPrice, ENTRY);
    }

    function testRejectsZeroAndRoundedToZeroPrice() public {
        _reject(trader, _openCall(true), _payload(SIGNER_KEY, BTC, 0, block.timestamp), _reason("Invalid oracle price"));
        _reject(
            trader,
            _openCall(true),
            _payload(SIGNER_KEY, BTC, 1e10 - 1, block.timestamp),
            _reason("Invalid oracle price")
        );
    }

    function testRejectsTimestampRegressionWithinFreshnessWindow() public {
        _open(true);
        bytes32 id = _position(0).id;
        uint256 firstTimestamp = vm.getBlockTimestamp();
        vm.warp(block.timestamp + 10);
        _execute(trader, abi.encodeCall(dex.modifyTpSl, (id, 60_000e8, 0)), _price(ENTRY));
        assertEq(dex.lastPriceTimestamp(BTC), block.timestamp);
        _reject(
            trader,
            abi.encodeCall(dex.closePosition, (id)),
            _payload(SIGNER_KEY, BTC, ENTRY * 1e10, firstTimestamp),
            _reason("Oracle timestamp regression")
        );
        assertFalse(_position(0).isClosed);
    }

    function testSignerRotationRevokesOldKeyAndAcceptsNewKey() public {
        vm.prank(trader);
        vm.expectRevert("Not admin");
        dex.setAtlasSigner(vm.addr(OTHER_KEY));
        vm.expectRevert("Invalid signer");
        dex.setAtlasSigner(address(0));
        dex.setAtlasSigner(vm.addr(OTHER_KEY));
        _reject(
            trader,
            _openCall(true),
            _price(ENTRY),
            abi.encodeWithSelector(IPullOracleBase.UnauthorizedSigner.selector, vm.addr(SIGNER_KEY))
        );
        _execute(trader, _openCall(true), _payload(OTHER_KEY, BTC, ENTRY * 1e10, block.timestamp));
        assertEq(_position(0).entryPrice, ENTRY);
    }

    function testNoNativeOracleFeeAccepted() public {
        bytes memory callData = bytes.concat(_openCall(true), _price(ENTRY));
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        (bool ok,) = address(dex).call{value: 1}(callData);
        assertFalse(ok);
        assertEq(address(dex).balance, 0);
    }

    function testCloseCapsProfitAndReleasesExposure() public {
        _open(true);
        bytes32 id = _position(0).id;
        _execute(trader, abi.encodeCall(dex.closePosition, (id)), _price(100_000e8));
        PerpDexAtlas.Position memory p = _position(0);
        assertTrue(p.isClosed);
        assertEq(p.closePrice, 100_000e8);
        // Gross profit capped at 500 USDC; winning fee remains 3.5% of profit.
        assertEq(p.payout, 582_500_000);
        assertEq(usdc.balanceOf(trader), 1_482_500_000);
        assertEq(dex.secondaryVaultBalance(), 7_500_000);
        assertEq(dex.totalOpenMargin(), 0);
        assertEq(dex.totalWorstCaseProfit(), 0);
        assertEq(dex.pairInfo("BTC_USD").usedLiquidity, 0);
    }

    function testFuzzWinningFeeSplit(bool isLong, uint64 moveSeed) public {
        uint256 delta = bound(uint256(moveSeed), 1, ENTRY / 10);
        _open(isLong);
        uint256 closingPrice = isLong ? ENTRY + delta : ENTRY - delta;
        uint256 profit = MARGIN * 10 * delta / ENTRY;
        bytes32 id = _position(0).id;
        _execute(trader, abi.encodeCall(dex.closePosition, (id)), _price(closingPrice));
        uint256 fee = profit * 350 / 10_000;
        assertEq(_position(0).payout, MARGIN + profit - fee);
        assertEq(dex.secondaryVaultBalance(), profit * 150 / 10_000);
    }

    function testFuzzLossHasNoWinningFee(bool isLong, uint64 moveSeed) public {
        uint256 delta = bound(uint256(moveSeed), 0, ENTRY / 100);
        _open(isLong);
        bytes32 id = _position(0).id;
        _execute(trader, abi.encodeCall(dex.closePosition, (id)), _price(isLong ? ENTRY - delta : ENTRY + delta));
        assertEq(_position(0).payout, MARGIN - MARGIN * 10 * delta / ENTRY);
        assertEq(dex.secondaryVaultBalance(), 0);
    }

    function testModifyUsesPriceInCurrentPayload() public {
        _open(true);
        bytes32 id = _position(0).id;
        _reject(
            trader,
            abi.encodeCall(dex.modifyTpSl, (id, 52_000e8, 0)),
            _price(55_000e8),
            _reason("Long TP must be above current price")
        );
        _execute(trader, abi.encodeCall(dex.modifyTpSl, (id, 60_000e8, 45_000e8)), _price(55_000e8));
        assertEq(_position(0).takeProfit, 60_000e8);
        assertEq(_position(0).stopLoss, 45_000e8);
    }

    function testFuzzTriggerTpSl(bool isLong, bool hitTP) public {
        uint256 tp = isLong ? 55_000e8 : 45_000e8;
        uint256 sl = isLong ? 49_000e8 : 51_000e8;
        _execute(trader, abi.encodeCall(dex.openPosition, ("BTC_USD", isLong, MARGIN, 10, tp, sl)), _price(ENTRY));
        bytes32 id = _position(0).id;
        _reject(
            address(this), abi.encodeCall(dex.triggerTpSl, (trader, id)), _price(ENTRY), _reason("No TP/SL triggered")
        );
        _execute(address(this), abi.encodeCall(dex.triggerTpSl, (trader, id)), _price(hitTP ? tp : sl));
        assertTrue(_position(0).isClosed);
        assertEq(_position(0).closePrice, hitTP ? tp : sl);
    }

    function testFuzzLiquidationUsesVerifiedPrice(bool isLong) public {
        _open(isLong);
        bytes32 id = _position(0).id;
        _execute(address(this), abi.encodeCall(dex.liquidate, (trader, id)), _price(isLong ? 45_000e8 : 55_000e8));
        assertTrue(_position(0).isClosed);
        assertEq(_position(0).payout, 0);
        assertEq(dex.totalOpenMargin(), 0);
        assertEq(dex.totalWorstCaseProfit(), 0);
    }

    function testEveryExitAndModifyRejectsStalePayload() public {
        _open(true);
        bytes32 id = _position(0).id;
        bytes memory stale = _payload(SIGNER_KEY, BTC, ENTRY * 1e10, block.timestamp - 61);
        bytes memory reason = _reason("Stale oracle price");
        _reject(trader, abi.encodeCall(dex.closePosition, (id)), stale, reason);
        _reject(trader, abi.encodeCall(dex.modifyTpSl, (id, 60_000e8, 0)), stale, reason);
        _reject(address(this), abi.encodeCall(dex.triggerTpSl, (trader, id)), stale, reason);
        _reject(address(this), abi.encodeCall(dex.liquidate, (trader, id)), stale, reason);
        _reject(address(this), abi.encodeCall(dex.closeAllPositions, ()), stale, reason);
        assertFalse(_position(0).isClosed);
    }

    function testEmergencyCloseRequiresAllFeedsAndIsAtomic() public {
        dex.addPair("ETH_USD", ETH, 20, 50_000e6, 2, 100, 5e18);
        _open(true);
        _execute(
            trader,
            abi.encodeCall(dex.openPosition, ("ETH_USD", true, MARGIN, 10, 0, 0)),
            _payload(SIGNER_KEY, ETH, 3_000e18, block.timestamp)
        );
        assertTrue(_position(0).id != _position(1).id);
        _reject(
            address(this),
            abi.encodeCall(dex.closeAllPositions, ()),
            _price(ENTRY),
            abi.encodeWithSelector(IPullOracleBase.UnmatchedFeedID.selector, ETH)
        );
        assertFalse(_position(0).isClosed);
        assertFalse(_position(1).isClosed);
        bytes memory packages = abi.encodePacked(
            BTC, uint80(ENTRY * 1e10), uint48(block.timestamp), ETH, uint80(3_000e18), uint48(block.timestamp)
        );
        _execute(address(this), abi.encodeCall(dex.closeAllPositions, ()), _signPackages(SIGNER_KEY, packages, 2));
        assertTrue(_position(0).isClosed);
        assertTrue(_position(1).isClosed);
        assertEq(dex.totalOpenMargin(), 0);
        assertEq(dex.totalWorstCaseProfit(), 0);
    }

    function testTraderTrackingDoesNotRequireUsernameOrDuplicateUsers() public {
        _open(true);
        assertEq(dex.allUsers(0), trader);
        vm.prank(trader);
        dex.registerUsername("atlas-user");
        _open(false);
        vm.expectRevert();
        dex.allUsers(1);
    }

    function testRuntimeFitsEip170() public view {
        assertLe(address(dex).code.length, 24_576);
    }

    function _open(bool isLong) internal {
        _execute(trader, _openCall(isLong), _price(ENTRY));
    }

    function _openCall(bool isLong) internal view returns (bytes memory) {
        return abi.encodeCall(dex.openPosition, ("BTC_USD", isLong, MARGIN, 10, 0, 0));
    }

    function _price(uint256 price8) internal view returns (bytes memory) {
        return _payload(SIGNER_KEY, BTC, price8 * 1e10, block.timestamp);
    }

    function _payload(uint256 key, bytes4 feed, uint256 price18, uint256 timestamp)
        internal
        pure
        returns (bytes memory)
    {
        require(price18 <= type(uint80).max && timestamp <= type(uint48).max, "Invalid test fixture");
        return _signPackages(key, abi.encodePacked(feed, uint80(price18), uint48(timestamp)), 1);
    }

    function _signPackages(uint256 key, bytes memory packages, uint8 count) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked(packages, count)));
        return abi.encodePacked(packages, count, r, s, v, uint16(0x7096));
    }

    function _execute(address sender, bytes memory callData, bytes memory payload) internal {
        vm.prank(sender);
        (bool ok, bytes memory result) = address(dex).call(bytes.concat(callData, payload));
        if (!ok) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
    }

    function _reject(address sender, bytes memory callData, bytes memory payload, bytes memory expected) internal {
        vm.prank(sender);
        (bool ok, bytes memory reason) = address(dex).call(bytes.concat(callData, payload));
        assertFalse(ok, "Expected rejection");
        assertEq(reason, expected);
    }

    function _reason(string memory message) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", message);
    }

    function _position(uint256 index) internal view returns (PerpDexAtlas.Position memory p) {
        // Public mapping getter returns the tuple in the same order as Position.
        (bool ok, bytes memory data) =
            address(dex).staticcall(abi.encodeWithSignature("positions(address,uint256)", trader, index));
        require(ok, "Position getter failed");
        // The getter flattens the struct tuple; wrap it in the offset expected for a dynamic struct.
        p = abi.decode(bytes.concat(bytes32(uint256(32)), data), (PerpDexAtlas.Position));
    }
}
