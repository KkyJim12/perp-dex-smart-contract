// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/OneClickPerpDex.sol";
import "../src/PerpDex.sol";

/// @dev Canonical initial pair configuration shared by deployment scripts.
///      maxTP uses 18 decimals: 1e18 = 100% gross profit on margin.
abstract contract InitialPairConfig {
    uint256 internal constant INITIAL_MAX_TP = 5e18;

    function _configurePerpDex(PerpDex dex) internal {
        // dex.addPair("BTC_USD", 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43, 20, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("ETH_USD", 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace, 10, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("SOL_USD", 0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d, 10, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("BNB_USD", 0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f, 10, 50000e6, 2, 75, INITIAL_MAX_TP);
        // dex.addPair("XRP_USD", 0xec5d399846a9209f3fe5881d70aae9268c94339ff9817e8d18ff19fa05eea1c8, 5, 50000e6, 2, 75, INITIAL_MAX_TP);
        // dex.addPair("HYPE_USD", 0x4279e31cc369bbcc2faf022b382b080e32a8e689ff20fbc530d2a603eb6cd98b, 2, 50000e6, 2, 50, INITIAL_MAX_TP);
        // dex.addPair("MON_USD", 0x31491744e2dbf6df7fcf4ac0820d18a609b49076d45066d3568424e62f686cd1, 3, 50000e6, 2, 50, INITIAL_MAX_TP);
        // dex.addPair("SUI_USD", 0x23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744, 5, 50000e6, 2, 50, INITIAL_MAX_TP);
        // dex.addPair("OP_USD", 0x385f64d993f7b77d8182ed5003d97c60aa3361f3cecfe711544d2d59165e9bdf, 5, 50000e6, 2, 50, INITIAL_MAX_TP);
        // dex.addPair("ARB_USD", 0x3fa4252848f9f0a1480be62745a4629d9eb1322aebab8a791e344b3b9c1adcf5, 5, 50000e6, 2, 50, INITIAL_MAX_TP);
        // dex.addPair("ZRO_USD", 0x3bd860bea28bf982fa06bcf358118064bb114086cc03993bd76197eaab0b8018, 2, 50000e6, 2, 50, INITIAL_MAX_TP);
        // dex.addPair("JUP_USD", 0x0a0408d619e9380abad35060f9192039ed5042fa6f82301d0e48bb52be830996, 3, 50000e6, 2, 50, INITIAL_MAX_TP);
        // dex.addPair("LINK_USD", 0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221, 5, 50000e6, 2, 50, INITIAL_MAX_TP);
        // dex.addPair("DOGE_USD", 0xdcef50dd0a4cd2dcc17e45df1676dcb336a11a61c69df7a0299b0150c672d25c, 5, 50000e6, 2, 50, INITIAL_MAX_TP);
        // dex.addPair("PYTH_USD", 0x0bbf28e9a841a1cc788f6a361b17ca072d0ea3098a1e5df1c3922d06719579ff, 3, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("SHIB_USD", 0xf0d57deca57b3da2fe63a493f4c25925fdfd8edf834b20f93e1f84dbd1504d4a, 2, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("BONK_USD", 0x72b021217ca3fe68922a19aaf990109cb9d84e9ad004b4d2025ad6f529314419, 2, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("PEPE_USD", 0xd69731a2e74ac1ce884fc3890f7ee324b6deb66147055249568869ed700882e4, 2, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("META", 0x78a3e3b8e676a8f73c439f5d749737034b139bbbe899ba5775216fba596607fe, 10, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("TSLA", 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1, 10, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("NVDA", 0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593, 5, 50000e6, 2, 5, INITIAL_MAX_TP);
        // dex.addPair("MSFT", 0xd0ca23c1cc005e004ccf1db5bf76aeb6a49218f43dac3d4b275e92de12ded4d1, 10, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("COIN", 0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245, 8, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("GOOGL", 0x5a48c03e9b9cb337801073ed9d166817473697efff0d138874e0f6a33d6d5aa6, 10, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("AAPL", 0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688, 10, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("AMZN", 0xb5d0e0fa58a1f8b81498ae670ce93c872d14434b72c364885d4fa1b257cbb07a, 10, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("EURUSD", 0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b, 20, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("GBPUSD", 0x84c2dde9633d93d1bcad84e7dc41c9d56578b7ec52fabedc1f335d673df0a7c1, 15, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("USDJPY", 0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52, 15, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("AUDUSD", 0x67a6f93030420c1c9e3fe37c1ab6b77966af82f995944a9fefce357a22854a80, 10, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("USDCAD", 0x3112b03a41c910ed446852aacf67118cb1bec67b2cd0b9a214c58cc0eaa2ecca, 10, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("USDCHF", 0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8, 10, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("NZDUSD", 0x92eea8ba1b00078cdc2ef6f64f091f262e8c7d0576ee4677572f314ebfcc9806, 8, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("QQQ", 0x9695e2b96ea7b3859da9ed25b7a46a920a776e2fdae19a7bcfdf2b219230452d, 15, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("SPY", 0x19e09bb805456ada3979a7d1cbb4b6d63babc3a0f8e8a9509f68afa5c4c11cd5, 15, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("XAG_USD", 0xf2fb02c32b055c805e7238d628e5e9dadef274376114eb1f012337cabe93871e, 10, 2000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("XAU_USD", 0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2, 10, 2000e6, 2, 100, INITIAL_MAX_TP);
    }

    function _configureOneClickPerpDex(OneClickPerpDex dex) internal {
        // dex.addPair("BTC_USD", 2000, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("ETH_USD", 1000, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("SOL_USD", 1000, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("BNB_USD", 1000, 50000e6, 2, 75, INITIAL_MAX_TP);
        // dex.addPair("XRP_USD", 500, 50000e6, 2, 75, INITIAL_MAX_TP);
        // dex.addPair("HYPE_USD", 200, 50000e6, 2, 50, INITIAL_MAX_TP);
        // dex.addPair("MON_USD", 300, 50000e6, 2, 50, INITIAL_MAX_TP);
        // dex.addPair("SUI_USD", 500, 50000e6, 2, 50, INITIAL_MAX_TP);
        // dex.addPair("OP_USD", 500, 50000e6, 2, 50, INITIAL_MAX_TP);
        // dex.addPair("ARB_USD", 500, 50000e6, 2, 50, INITIAL_MAX_TP);
        // dex.addPair("ZRO_USD", 200, 50000e6, 2, 50, INITIAL_MAX_TP);
        // dex.addPair("JUP_USD", 300, 50000e6, 2, 50, INITIAL_MAX_TP);
        // dex.addPair("LINK_USD", 500, 50000e6, 2, 50, INITIAL_MAX_TP);
        // dex.addPair("PYTH_USD", 300, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("DOGE_USD", 500, 50000e6, 2, 50, INITIAL_MAX_TP);
        // dex.addPair("SHIB_USD", 200, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("BONK_USD", 200, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("PEPE_USD", 200, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("META", 1000, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("TSLA", 1000, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("NVDA", 500, 50000e6, 2, 5, INITIAL_MAX_TP);
        // dex.addPair("MSFT", 1000, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("COIN", 800, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("GOOGL", 1000, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("AAPL", 1000, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("AMZN", 1000, 50000e6, 2, 25, INITIAL_MAX_TP);
        // dex.addPair("EURUSD", 2000, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("GBPUSD", 1500, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("USDJPY", 1500, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("AUDUSD", 1000, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("USDCAD", 1000, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("USDCHF", 1000, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("NZDUSD", 800, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("QQQ", 1500, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("SPY", 1500, 50000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("XAG_USD", 1000, 2000e6, 2, 100, INITIAL_MAX_TP);
        // dex.addPair("XAU_USD", 1000, 2000e6, 2, 100, INITIAL_MAX_TP);
    }
}
