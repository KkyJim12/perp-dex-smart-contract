// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ConfigureAtlasPairs} from "../script/ConfigureAtlasPairs.s.sol";
import {PerpDexAtlas} from "../src/PerpDexAtlas.sol";
import {OptionAMMAtlas} from "../src/OptionAMMAtlas.sol";
import {PredictionMarketAMMAtlas} from "../src/PredictionMarketAMMAtlas.sol";

contract AtlasPairSeedFixture is ConfigureAtlasPairs {
    SeedConfig private config;
    mapping(string => bytes) private feeds;
    mapping(string => bool) private overrides;
    bool private defaultsOnly;

    constructor(SeedConfig memory fixtureConfig) {
        config = fixtureConfig;
    }

    function setFeed(string calldata variable, bytes calldata raw) external {
        overrides[variable] = true;
        feeds[variable] = raw;
    }

    function useDefaultFeeds() external {
        defaultsOnly = true;
    }

    function _seedConfig() internal view override returns (SeedConfig memory) {
        return config;
    }

    function _atlasFeedBytes(string memory variable) internal view override returns (bytes memory) {
        if (overrides[variable]) return feeds[variable];
        if (defaultsOnly) return hex"";
        // Test-only synthetic IDs; production requires the IDs supplied by Atlas.
        return abi.encodePacked(bytes4(keccak256(bytes(variable))));
    }
}

contract ConfigureAtlasPairsTest is Test {
    PerpDexAtlas private perp;
    OptionAMMAtlas private option;
    PredictionMarketAMMAtlas private prediction;
    ConfigureAtlasPairs.SeedConfig private config;

    function setUp() public {
        address collateral = deployCode("MockUSDC.sol:MockUSDC");
        address signer = makeAddr("atlas-signer");
        vm.startPrank(vm.addr(1));
        address perpShares = deployCode("ppUSDC.sol:ppUSDC");
        address optionShares = deployCode("opUSDC.sol:opUSDC");
        perp = PerpDexAtlas(deployCode("PerpDexAtlas.sol:PerpDexAtlas", abi.encode(collateral, perpShares, signer, 5)));
        option = OptionAMMAtlas(
            deployCode("OptionAMMAtlas.sol:OptionAMMAtlas", abi.encode(collateral, signer, optionShares))
        );
        prediction = PredictionMarketAMMAtlas(
            deployCode("PredictionMarketAMMAtlas.sol:PredictionMarketAMMAtlas", abi.encode(collateral, signer, 300))
        );
        vm.stopPrank();
        config = ConfigureAtlasPairs.SeedConfig(1, address(perp), address(option), address(prediction));
    }

    function _script() private returns (AtlasPairSeedFixture) {
        return AtlasPairSeedFixture(deployCode("ConfigureAtlasPairs.t.sol:AtlasPairSeedFixture", abi.encode(config)));
    }

    function testSeedAllWithCanonicalRiskSettingsAndSharedFeedMappings() public {
        _script().run();
        string[15] memory names = [
            "BTC_USD",
            "ETH_USD",
            "SOL_USD",
            "BNB_USD",
            "HYPE_USD",
            "DOGE_USD",
            "XRP_USD",
            "ZEC_USD",
            "AAPL_USD",
            "MSFT_USD",
            "AMZN_USD",
            "GOOGL_USD",
            "META_USD",
            "NVDA_USD",
            "TSLA_USD"
        ];
        string[15] memory variables = [
            "ATLAS_BTC_FEED_ID",
            "ATLAS_ETH_FEED_ID",
            "ATLAS_SOL_FEED_ID",
            "ATLAS_BNB_FEED_ID",
            "ATLAS_HYPE_FEED_ID",
            "ATLAS_DOGE_FEED_ID",
            "ATLAS_XRP_FEED_ID",
            "ATLAS_ZEC_FEED_ID",
            "ATLAS_AAPL_FEED_ID",
            "ATLAS_MSFT_FEED_ID",
            "ATLAS_AMZN_FEED_ID",
            "ATLAS_GOOGL_FEED_ID",
            "ATLAS_META_FEED_ID",
            "ATLAS_NVDA_FEED_ID",
            "ATLAS_TSLA_FEED_ID"
        ];
        uint256[6] memory weights = [uint256(20), 10, 10, 10, 2, 5];
        for (uint256 i; i < names.length; ++i) {
            PerpDexAtlas.PairInfo memory pair = perp.allPairs(i);
            assertEq(pair.name, names[i]);
            assertEq(pair.atlasFeedId, bytes4(keccak256(bytes(variables[i]))));
            assertEq(pair.liquidityRatio, i < 6 ? weights[i] : 5);
            assertEq(pair.minLeverage, 2);
            assertEq(pair.maxLeverage, i < 3 ? 500 : (i < 8 ? 250 : 100));
            assertEq(pair.maxPositionSize, i < 8 ? 500_000e6 : 50_000e6);
            assertEq(pair.maxTP, 5e18);
            assertTrue(pair.active);
        }
        assertEq(perp.totalLiquidityRatio(), 102);
        vm.expectRevert();
        perp.allPairs(15);
        _assertAmmPairs();
    }

    function _assertAmmPairs() private view {
        assertEq(option.pairCount(), 3);
        assertEq(prediction.pairCount(), 15);
        string[3] memory names = ["BTC", "ETH", "SOL"];
        string[3] memory perpNames = ["BTC_USD", "ETH_USD", "SOL_USD"];
        for (uint256 i; i < 3; ++i) {
            (string memory name, bytes4 feed, bool active) = option.pairs(i);
            assertEq(name, names[i]);
            assertTrue(active);
            assertEq(feed, perp.pairInfo(perpNames[i]).atlasFeedId);
            (name, feed, active) = prediction.pairs(i);
            assertEq(name, names[i]);
            assertTrue(active);
            assertEq(feed, option.atlasFeedIds(i));
        }
        for (uint256 i; i < 15; ++i) {
            (string memory name, bytes4 feed, bool active) = prediction.pairs(i);
            PerpDexAtlas.PairInfo memory pair = perp.allPairs(i);
            assertEq(string.concat(name, "_USD"), pair.name);
            assertEq(feed, pair.atlasFeedId);
            assertTrue(active);
        }
    }

    function testOptionOnlyNeedsThreeFeeds() public {
        config.perp = address(0);
        config.prediction = address(0);
        AtlasPairSeedFixture script = _script();
        script.setFeed("ATLAS_BNB_FEED_ID", hex"");
        script.run();
        assertEq(option.pairCount(), 3);
        assertEq(prediction.pairCount(), 0);
        assertEq(perp.totalLiquidityRatio(), 0);
    }

    function testPredictionOnlySeedsAll15Feeds() public {
        config.perp = address(0);
        config.option = address(0);
        AtlasPairSeedFixture script = _script();
        script.run();
        assertEq(prediction.pairCount(), 15);
        (string memory name, bytes4 feed, bool active) = prediction.pairs(14);
        assertEq(name, "TSLA");
        assertEq(feed, bytes4(keccak256("ATLAS_TSLA_FEED_ID")));
        assertTrue(active);
        assertEq(option.pairCount(), 0);
        assertEq(perp.totalLiquidityRatio(), 0);
    }

    function testPerpOnlyLeavesAmmsEmpty() public {
        config.option = address(0);
        config.prediction = address(0);
        _script().run();
        assertEq(perp.totalLiquidityRatio(), 102);
        assertEq(option.pairCount(), 0);
        assertEq(prediction.pairCount(), 0);
    }

    function _assertEmpty() private view {
        assertEq(perp.totalLiquidityRatio(), 0);
        assertEq(option.pairCount(), 0);
        assertEq(prediction.pairCount(), 0);
    }

    function testMalformedLastFeedRejectsBeforeAnyPairIsAdded() public {
        AtlasPairSeedFixture script = _script();
        script.setFeed("ATLAS_TSLA_FEED_ID", hex"010203");
        vm.expectRevert("ATLAS_TSLA_FEED_ID must be exactly 4 bytes");
        script.run();
        _assertEmpty();
    }

    function testBlankNewCryptoOverrideUsesPrivateDefault() public {
        AtlasPairSeedFixture script = _script();
        script.setFeed("ATLAS_XRP_FEED_ID", hex"");
        script.run();
        assertEq(perp.pairInfo("XRP_USD").atlasFeedId, bytes4(0x000004ad));
        assertEq(prediction.atlasFeedIds(6), bytes4(0x000004ad));
    }

    function testDefaultFeedIdsMatchUserPrivateFeedsScreenshot() public {
        AtlasPairSeedFixture script = _script();
        script.useDefaultFeeds();
        // An explicitly blank override also uses the default.
        script.setFeed("ATLAS_BTC_FEED_ID", hex"");
        script.run();
        bytes4[15] memory expected = [
            bytes4(0x000004a6),
            bytes4(0x000004a7),
            bytes4(0x000004a9),
            bytes4(0x000004aa),
            bytes4(0x000004ab),
            bytes4(0x000004ac),
            bytes4(0x000004ad),
            bytes4(0x000004ae),
            bytes4(0x000004af),
            bytes4(0x000004b0),
            bytes4(0x000004b2),
            bytes4(0x000004b1),
            bytes4(0x000004b4),
            bytes4(0x000004b3),
            bytes4(0x000004b5)
        ];
        string[15] memory names = [
            "BTC_USD",
            "ETH_USD",
            "SOL_USD",
            "BNB_USD",
            "HYPE_USD",
            "DOGE_USD",
            "XRP_USD",
            "ZEC_USD",
            "AAPL_USD",
            "MSFT_USD",
            "AMZN_USD",
            "GOOGL_USD",
            "META_USD",
            "NVDA_USD",
            "TSLA_USD"
        ];
        for (uint256 i; i < expected.length; ++i) {
            PerpDexAtlas.PairInfo memory pair = perp.allPairs(i);
            assertEq(pair.name, names[i]);
            assertEq(pair.atlasFeedId, expected[i]);
        }
        assertEq(perp.totalLiquidityRatio(), 102);
        vm.expectRevert();
        perp.allPairs(15);
        _assertAmmPairs();
    }

    function testExplicitFeedOverrideAppliesToAllVaults() public {
        AtlasPairSeedFixture script = _script();
        script.setFeed("ATLAS_BTC_FEED_ID", hex"11223344");
        script.run();
        assertEq(perp.pairInfo("BTC_USD").atlasFeedId, bytes4(0x11223344));
        assertEq(option.atlasFeedIds(0), bytes4(0x11223344));
        assertEq(prediction.atlasFeedIds(0), bytes4(0x11223344));
    }

    function testConfiguredStockIsAddedWithStockRiskSettings() public {
        AtlasPairSeedFixture script = _script();
        script.setFeed("ATLAS_TSLA_FEED_ID", hex"11223344");
        script.run();
        PerpDexAtlas.PairInfo memory pair = perp.allPairs(14);
        assertEq(pair.name, "TSLA_USD");
        assertEq(pair.atlasFeedId, bytes4(0x11223344));
        assertEq(pair.maxPositionSize, 50_000e6);
        assertEq(pair.maxLeverage, 100);
        assertEq(perp.totalLiquidityRatio(), 102);
        vm.expectRevert();
        perp.allPairs(15);
    }

    function testRejectsTruncatedPythFeedBeforeBroadcast() public {
        AtlasPairSeedFixture script = _script();
        script.setFeed("ATLAS_BTC_FEED_ID", abi.encode(bytes32(uint256(1))));
        vm.expectRevert("ATLAS_BTC_FEED_ID must be exactly 4 bytes");
        script.run();
        _assertEmpty();
    }

    function testRejectsZeroFeedBeforeBroadcast() public {
        AtlasPairSeedFixture script = _script();
        script.setFeed("ATLAS_BTC_FEED_ID", hex"00000000");
        vm.expectRevert("ATLAS_BTC_FEED_ID must be nonzero");
        script.run();
        _assertEmpty();
    }

    function testRejectsDuplicateFeedsBeforeBroadcast() public {
        AtlasPairSeedFixture script = _script();
        script.setFeed("ATLAS_BTC_FEED_ID", hex"11223344");
        script.setFeed("ATLAS_ETH_FEED_ID", hex"11223344");
        vm.expectRevert("Duplicate Atlas feed ID");
        script.run();
        _assertEmpty();
    }

    function testChecksAllOwnersBeforeBroadcast() public {
        address newOwner = makeAddr("new-owner");
        vm.prank(vm.addr(1));
        option.transferOwnership(newOwner);
        vm.prank(newOwner);
        option.acceptOwnership();
        AtlasPairSeedFixture script = _script();
        vm.expectRevert("Signer is not Atlas option owner");
        script.run();
        _assertEmpty();
    }

    function testChecksAllRegistriesBeforeBroadcast() public {
        vm.prank(vm.addr(1));
        option.addPair("EXISTING", bytes4(0x11223344));
        AtlasPairSeedFixture script = _script();
        vm.expectRevert("Atlas option pairs already initialized");
        script.run();
        assertEq(perp.totalLiquidityRatio(), 0);
        assertEq(prediction.pairCount(), 0);
        assertEq(option.pairCount(), 1);
    }

    function testRejectsRerunsWithoutAddingDuplicates() public {
        AtlasPairSeedFixture script = _script();
        script.run();
        vm.expectRevert("Atlas perp pairs already initialized");
        script.run();
        assertEq(perp.totalLiquidityRatio(), 102);
        assertEq(option.pairCount(), 3);
        assertEq(prediction.pairCount(), 15);
    }

    function testRejectsMissingContractBeforeBroadcast() public {
        config.prediction = address(0x1234);
        AtlasPairSeedFixture script = _script();
        vm.expectRevert("No PredictionMarketAMMAtlas at target");
        script.run();
        _assertEmpty();
    }
}
