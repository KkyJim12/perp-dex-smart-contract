// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PredictionMarketAMM} from "../src/PredictionMarketAMM.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {PythStructs} from "lib/pyth-sdk-solidity/PythStructs.sol";
import {ConfigurePredictionPairs} from "../script/ConfigureInitialPairs.s.sol";

contract PredictionPairsMockPyth {
    bytes32 public expectedId;
    function setExpectedId(bytes32 id) external { expectedId = id; }
    function getUpdateFee(bytes[] calldata) external pure returns (uint256) { return 0; }
    function parsePriceFeedUpdatesUnique(bytes[] calldata, bytes32[] calldata ids, uint64 minTime, uint64)
        external payable returns (PythStructs.PriceFeed[] memory feeds)
    {
        require(ids.length == 1 && ids[0] == expectedId, "Unexpected feed");
        feeds = new PythStructs.PriceFeed[](1);
        PythStructs.Price memory price = PythStructs.Price(100, 0, 0, minTime);
        feeds[0] = PythStructs.PriceFeed(ids[0], price, price);
    }
}

contract PredictionMarketPairsTest is Test {
    PredictionMarketAMM amm;
    MockUSDC usdc;
    PredictionPairsMockPyth pyth;
    bytes32 constant BTC = bytes32(uint256(1));

    function setUp() public {
        usdc = new MockUSDC();
        pyth = new PredictionPairsMockPyth();
        amm = new PredictionMarketAMM(address(usdc), address(pyth), 30);
    }

    function testAddRemoveAndReaddUseStableIds() public {
        for (uint256 i; i < 5; ++i) {
            assertEq(amm.addPair(vm.toString(i), bytes32(i + 1)), i);
        }
        amm.removePair(1);
        assertEq(amm.addPair("1", bytes32(uint256(2))), 5);
        assertEq(amm.pairCount(), 6);
        (, bytes32 feed, bool active) = amm.pairs(1);
        assertEq(feed, bytes32(uint256(2)));
        assertFalse(active);
        (, feed, active) = amm.pairs(2);
        assertEq(feed, bytes32(uint256(3)));
        assertTrue(active);
        uint256 market = amm.createMarket(5, 300, 300, 1_000e6);
        assertEq(amm.getMarket(market).pairId, 5);
    }

    function testOnlyOwnerCanManagePairs() public {
        vm.prank(address(0x123));
        vm.expectRevert();
        amm.addPair("BTC_USD", BTC);
        amm.addPair("BTC_USD", BTC);
        vm.prank(address(0x123));
        vm.expectRevert();
        amm.removePair(0);
    }

    function testInvalidAndDuplicatePairsRevert() public {
        vm.expectRevert("Invalid name");
        amm.addPair("", BTC);
        vm.expectRevert("Invalid feed");
        amm.addPair("BTC_USD", bytes32(0));
        amm.addPair("BTC_USD", BTC);
        vm.expectRevert("Duplicate pair");
        amm.addPair("BTC_USD", bytes32(uint256(2)));
        vm.expectRevert("Duplicate feed");
        amm.addPair("OTHER", BTC);
        vm.expectRevert("Invalid pair");
        amm.removePair(1);
        vm.expectRevert("Invalid pair");
        amm.createMarket(1, 300, 300, 1_000e6);
        amm.removePair(0);
        vm.expectRevert("Pair inactive");
        amm.removePair(0);
        vm.expectRevert("Pair inactive");
        amm.createMarket(0, 300, 300, 1_000e6);
    }

    function testRemovedPairCanOpenTradeResolveAndClaimWithOriginalFeed() public {
        amm.addPair("BTC_USD", BTC);
        uint256 id = amm.createMarket(0, 300, 300, 1_000e6);
        amm.removePair(0);
        amm.addPair("BTC_USD", bytes32(uint256(2)));
        pyth.setExpectedId(BTC);
        usdc.ownerMint(address(this), 20_000e6);
        usdc.approve(address(amm), type(uint256).max);
        amm.deposit(10_000e6, 0);
        vm.warp(300);
        amm.openMarket(id, new bytes[](0));
        uint256 shares = amm.buy(id, true, 100e6, 0, block.timestamp);
        vm.warp(600);
        amm.resolveMarket(id, new bytes[](0));
        uint256 beforeBalance = usdc.balanceOf(address(this));
        assertEq(amm.claim(id, address(this)), shares);
        assertEq(usdc.balanceOf(address(this)), beforeBalance + shares);
        assertEq(amm.reservedPayout(), 0);
        assertEq(amm.unresolvedExposureMarkets(), 0);
    }

    function testSeedScriptAddsCanonicalPairsAndRejectsRerun() public {
        ConfigurePredictionPairs script = ConfigurePredictionPairs(deployCode("ConfigureInitialPairs.s.sol:ConfigurePredictionPairs"));
        vm.setEnv("PRIVATE_KEY", "1");
        vm.setEnv("PREDICTION_MARKET_AMM_ADDRESS", vm.toString(address(amm)));
        vm.expectRevert("Signer is not prediction owner");
        script.run();
        amm.transferOwnership(vm.addr(1));
        vm.prank(vm.addr(1));
        amm.acceptOwnership();
        script.run();
        assertEq(amm.pairCount(), 3);
        (string memory name,, bool active) = amm.pairs(0);
        assertEq(name, "BTC_USD");
        assertTrue(active);
        (name,, active) = amm.pairs(1);
        assertEq(name, "ETH_USD");
        assertTrue(active);
        (name,, active) = amm.pairs(2);
        assertEq(name, "SOL_USD");
        assertTrue(active);
        assertEq(amm.priceIds(0), 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43);
        assertEq(amm.priceIds(1), 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace);
        assertEq(amm.priceIds(2), 0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d);
        vm.expectRevert("Prediction pairs already initialized");
        script.run();
    }
}
