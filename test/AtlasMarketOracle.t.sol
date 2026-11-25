// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AtlasMarketOracle} from "../src/oracle/AtlasMarketOracle.sol";
import {IPullOracleBase} from "lib/pull-oracle-consumer/src/interfaces/IPullOracleBase.sol";
import {AtlasSignedTest} from "./helpers/AtlasSignedTest.sol";

contract AtlasMarketOracleHarness is AtlasMarketOracle {
    constructor(address signer) AtlasMarketOracle(signer) {}

    function spot(bytes4 feed, uint64 start) external returns (uint256) {
        return _atlasSpotPrice(feed, start, 5);
    }

    function boundary(bytes4 feed, uint64 timestamp) external returns (uint256) {
        return _atlasBoundaryPrice(feed, timestamp);
    }
}

contract AtlasMarketOracleTest is AtlasSignedTest {
    AtlasMarketOracleHarness oracle;

    function setUp() public {
        vm.warp(1_000);
        oracle = new AtlasMarketOracleHarness(vm.addr(ATLAS_KEY));
    }

    function testSpotAcceptsFiveSecondBoundaryAndKeeps18Decimals() public {
        bytes memory result = _execute(
            address(oracle), address(this), abi.encodeCall(oracle.spot, (BTC, 900)), _payload(BTC, 100e18, 995)
        );
        assertEq(abi.decode(result, (uint256)), 100e18);
        assertEq(oracle.lastSpotTimestamp(BTC), 995);
    }

    function testSpotRejectsStalePreStartFutureAndZeroTimestamp() public {
        bytes memory callData = abi.encodeCall(oracle.spot, (BTC, 999));
        _reject(address(oracle), address(this), callData, _payload(BTC, 100e18, 998), _reason("Invalid publish time"));
        callData = abi.encodeCall(oracle.spot, (BTC, 900));
        _reject(address(oracle), address(this), callData, _payload(BTC, 100e18, 994), _reason("Invalid publish time"));
        _reject(
            address(oracle), address(this), callData, _payload(BTC, 100e18, 1001), _reason("Invalid oracle timestamp")
        );
        _reject(address(oracle), address(this), callData, _payload(BTC, 100e18, 0), _reason("Invalid oracle timestamp"));
    }

    function testRejectsWrongFeedAndUntrustedSigner() public {
        bytes memory callData = abi.encodeCall(oracle.spot, (BTC, 900));
        _reject(
            address(oracle),
            address(this),
            callData,
            _payload(ETH, 100e18, 1000),
            abi.encodeWithSelector(IPullOracleBase.UnmatchedFeedID.selector, BTC)
        );
        _reject(
            address(oracle),
            address(this),
            callData,
            _payloadWithKey(OTHER_KEY, BTC, 100e18, 1000),
            abi.encodeWithSelector(IPullOracleBase.UnauthorizedSigner.selector, vm.addr(OTHER_KEY))
        );
    }

    function testRejectsTamperingMissingPayloadAndZeroPrice() public {
        bytes memory callData = abi.encodeCall(oracle.spot, (BTC, 900));
        _reject(
            address(oracle),
            address(this),
            callData,
            "",
            abi.encodeWithSelector(IPullOracleBase.InsufficientMetadata.selector)
        );
        _reject(address(oracle), address(this), callData, _payload(BTC, 0, 1000), _reason("Invalid price"));
        bytes memory payload = _payload(BTC, 100e18, 1000);
        payload[4] = bytes1(uint8(payload[4]) ^ 1);
        vm.prank(address(this));
        (bool ok,) = address(oracle).call(bytes.concat(callData, payload));
        assertFalse(ok);
    }

    function testSpotRejectsRegressionAndConflictingSameTimestamp() public {
        bytes memory callData = abi.encodeCall(oracle.spot, (BTC, 900));
        _execute(address(oracle), address(this), callData, _payload(BTC, 100e18, 1000));
        _reject(
            address(oracle), address(this), callData, _payload(BTC, 100e18, 999), _reason("Oracle timestamp regression")
        );
        _reject(
            address(oracle), address(this), callData, _payload(BTC, 101e18, 1000), _reason("Conflicting spot price")
        );
        _execute(address(oracle), address(this), callData, _payload(BTC, 100e18, 1000));
    }

    function testBoundaryRequiresExactTimestampAndAcceptsHistoricalQuoteAfterNewerSpot() public {
        _execute(address(oracle), address(this), abi.encodeCall(oracle.spot, (BTC, 900)), _payload(BTC, 110e18, 1000));
        bytes memory callData = abi.encodeCall(oracle.boundary, (BTC, 600));
        _reject(
            address(oracle), address(this), callData, _payload(BTC, 100e18, 599), _reason("Wrong boundary timestamp")
        );
        _reject(
            address(oracle), address(this), callData, _payload(BTC, 100e18, 601), _reason("Wrong boundary timestamp")
        );
        bytes memory result = _execute(address(oracle), address(this), callData, _payload(BTC, 100e18, 600));
        assertEq(abi.decode(result, (uint256)), 100e18);
        assertEq(oracle.boundaryPrices(BTC, 600), 100e18);
        assertEq(oracle.lastSpotTimestamp(BTC), 1000);
    }

    function testBoundaryQuotesAreConsistentAndStillRequireSignaturesAfterCaching() public {
        bytes memory callData = abi.encodeCall(oracle.boundary, (BTC, 600));
        _execute(address(oracle), address(this), callData, _payload(BTC, 100e18, 600));
        _reject(
            address(oracle), address(this), callData, _payload(BTC, 101e18, 600), _reason("Conflicting boundary price")
        );
        _reject(
            address(oracle),
            address(this),
            callData,
            "",
            abi.encodeWithSelector(IPullOracleBase.InsufficientMetadata.selector)
        );
        _execute(address(oracle), address(this), callData, _payload(BTC, 100e18, 600));
    }

    function testSignerRotationIsOwnerOnlyAndRevokesOldKey() public {
        address other = makeAddr("other");
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", other));
        oracle.setAtlasSigner(vm.addr(OTHER_KEY));
        vm.expectRevert("Invalid signer");
        oracle.setAtlasSigner(address(0));
        oracle.setAtlasSigner(vm.addr(OTHER_KEY));
        bytes memory callData = abi.encodeCall(oracle.spot, (BTC, 900));
        _reject(
            address(oracle),
            address(this),
            callData,
            _payload(BTC, 100e18, 1000),
            abi.encodeWithSelector(IPullOracleBase.UnauthorizedSigner.selector, vm.addr(ATLAS_KEY))
        );
        _execute(address(oracle), address(this), callData, _payloadWithKey(OTHER_KEY, BTC, 100e18, 1000));
    }
}
