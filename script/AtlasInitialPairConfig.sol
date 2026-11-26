// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {PerpDexAtlas} from "../src/PerpDexAtlas.sol";
import {OptionAMMAtlas} from "../src/OptionAMMAtlas.sol";
import {PredictionMarketAMMAtlas} from "../src/PredictionMarketAMMAtlas.sol";

/// @dev Initial Atlas markets using Atlas-assigned bytes4 feeds.
abstract contract AtlasInitialPairConfig is Script {
    uint256 internal constant INITIAL_ATLAS_MAX_TP = 5e18;

    struct AtlasPair {
        string name;
        bytes4 feedId;
        uint256 weight;
        uint256 maxPositionSize;
        uint256 maxLeverage;
    }

    function _initialAtlasPairs(bool includeAllMarkets) internal view returns (AtlasPair[] memory pairs) {
        pairs = new AtlasPair[](includeAllMarkets ? 15 : 3);
        // Private Atlas feeds supplied by the user in the My Feeds screenshot.
        // BTC #1190 is quoted in USDT; BTC_USD remains the application market name.
        pairs[0] = _pair("BTC_USD", "ATLAS_BTC_FEED_ID", 0x000004a6, 20, 500_000e6, 500); // 1190
        pairs[1] = _pair("ETH_USD", "ATLAS_ETH_FEED_ID", 0x000004a7, 10, 500_000e6, 500); // 1191
        pairs[2] = _pair("SOL_USD", "ATLAS_SOL_FEED_ID", 0x000004a9, 10, 500_000e6, 500); // 1193
        if (includeAllMarkets) {
            pairs[3] = _pair("BNB_USD", "ATLAS_BNB_FEED_ID", 0x000004aa, 10, 500_000e6, 250); // 1194
            pairs[4] = _pair("HYPE_USD", "ATLAS_HYPE_FEED_ID", 0x000004ab, 2, 500_000e6, 250); // 1195
            pairs[5] = _pair("DOGE_USD", "ATLAS_DOGE_FEED_ID", 0x000004ac, 5, 500_000e6, 250); // 1196
            pairs[6] = _pair("XRP_USD", "ATLAS_XRP_FEED_ID", 0x000004ad, 5, 500_000e6, 250); // 1197
            pairs[7] = _pair("ZEC_USD", "ATLAS_ZEC_FEED_ID", 0x000004ae, 5, 500_000e6, 250); // 1198
            pairs[8] = _pair("AAPL_USD", "ATLAS_AAPL_FEED_ID", 0x000004af, 5, 50_000e6, 100); // 1199
            pairs[9] = _pair("MSFT_USD", "ATLAS_MSFT_FEED_ID", 0x000004b0, 5, 50_000e6, 100); // 1200
            pairs[10] = _pair("AMZN_USD", "ATLAS_AMZN_FEED_ID", 0x000004b2, 5, 50_000e6, 100); // 1202
            pairs[11] = _pair("GOOGL_USD", "ATLAS_GOOGL_FEED_ID", 0x000004b1, 5, 50_000e6, 100); // 1201
            pairs[12] = _pair("META_USD", "ATLAS_META_FEED_ID", 0x000004b4, 5, 50_000e6, 100); // 1204
            pairs[13] = _pair("NVDA_USD", "ATLAS_NVDA_FEED_ID", 0x000004b3, 5, 50_000e6, 100); // 1203
            pairs[14] = _pair("TSLA_USD", "ATLAS_TSLA_FEED_ID", 0x000004b5, 5, 50_000e6, 100); // 1205
        }
        for (uint256 i; i < pairs.length; ++i) {
            for (uint256 j; j < i; ++j) {
                require(pairs[i].feedId != pairs[j].feedId, "Duplicate Atlas feed ID");
            }
        }
    }

    function _pair(
        string memory name,
        string memory feedVariable,
        bytes4 defaultFeed,
        uint256 weight,
        uint256 size,
        uint256 leverage
    ) private view returns (AtlasPair memory) {
        bytes memory raw = _atlasFeedBytes(feedVariable);
        // Missing or blank overrides use the user-supplied private feed defaults.
        if (raw.length == 0) {
            require(defaultFeed != bytes4(0), string.concat(feedVariable, " is required"));
            return AtlasPair(name, defaultFeed, weight, size, leverage);
        }
        require(raw.length == 4, string.concat(feedVariable, " must be exactly 4 bytes"));
        bytes4 feed = bytes4(raw);
        require(feed != bytes4(0), string.concat(feedVariable, " must be nonzero"));
        return AtlasPair(name, feed, weight, size, leverage);
    }

    function _atlasFeedBytes(string memory variable) internal view virtual returns (bytes memory) {
        return vm.envOr(variable, bytes(""));
    }

    function _seedAtlasPerp(PerpDexAtlas dex, AtlasPair[] memory pairs) internal {
        for (uint256 i; i < pairs.length; ++i) {
            AtlasPair memory pair = pairs[i];
            dex.addPair(
                pair.name, pair.feedId, pair.weight, pair.maxPositionSize, 2, pair.maxLeverage, INITIAL_ATLAS_MAX_TP
            );
        }
    }

    function _seedAtlasOption(OptionAMMAtlas amm, AtlasPair[] memory pairs) internal {
        amm.addPair("BTC", pairs[0].feedId);
        amm.addPair("ETH", pairs[1].feedId);
        amm.addPair("SOL", pairs[2].feedId);
    }

    function _seedAtlasPrediction(PredictionMarketAMMAtlas amm, AtlasPair[] memory pairs) internal {
        for (uint256 i; i < pairs.length; ++i) {
            // AMMs use the ticker; perpetuals use TICKER_USD.
            bytes memory name = bytes(pairs[i].name);
            bytes memory ticker = new bytes(name.length - 4);
            for (uint256 j; j < ticker.length; ++j) ticker[j] = name[j];
            amm.addPair(string(ticker), pairs[i].feedId);
        }
    }
}
