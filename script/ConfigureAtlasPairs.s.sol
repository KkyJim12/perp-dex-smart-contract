// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AtlasInitialPairConfig} from "./AtlasInitialPairConfig.sol";
import {PerpDexAtlas} from "../src/PerpDexAtlas.sol";
import {OptionAMMAtlas} from "../src/OptionAMMAtlas.sol";
import {PredictionMarketAMMAtlas} from "../src/PredictionMarketAMMAtlas.sol";

/// @notice Seed initial pairs on deployed Atlas vaults owned by PRIVATE_KEY.
contract ConfigureAtlasPairs is AtlasInitialPairConfig {
    struct SeedConfig {
        uint256 key;
        address perp;
        address option;
        address prediction;
    }

    function run() external {
        SeedConfig memory config = _seedConfig();
        require(
            config.perp != address(0) || config.option != address(0) || config.prediction != address(0),
            "No Atlas targets"
        );
        // Resolve defaults/overrides and validate every configured feed before preparing transactions.
        AtlasPair[] memory pairs = _initialAtlasPairs(config.perp != address(0) || config.prediction != address(0));
        address owner = vm.addr(config.key);
        if (config.perp != address(0)) {
            require(config.perp.code.length > 0, "No PerpDexAtlas at target");
            PerpDexAtlas dex = PerpDexAtlas(config.perp);
            require(dex.owner() == owner, "Signer is not Atlas perp owner");
            // All registered pairs have strictly positive weights, including inactive pairs.
            require(dex.totalLiquidityRatio() == 0, "Atlas perp pairs already initialized");
        }
        if (config.option != address(0)) {
            require(config.option.code.length > 0, "No OptionAMMAtlas at target");
            OptionAMMAtlas amm = OptionAMMAtlas(config.option);
            require(amm.owner() == owner, "Signer is not Atlas option owner");
            require(amm.pairCount() == 0, "Atlas option pairs already initialized");
        }
        if (config.prediction != address(0)) {
            require(config.prediction.code.length > 0, "No PredictionMarketAMMAtlas at target");
            PredictionMarketAMMAtlas amm = PredictionMarketAMMAtlas(config.prediction);
            require(amm.owner() == owner, "Signer is not Atlas prediction owner");
            require(amm.pairCount() == 0, "Atlas prediction pairs already initialized");
        }

        vm.startBroadcast(config.key);
        if (config.perp != address(0)) _seedAtlasPerp(PerpDexAtlas(config.perp), pairs);
        if (config.option != address(0)) _seedAtlasOption(OptionAMMAtlas(config.option), pairs);
        if (config.prediction != address(0)) _seedAtlasPrediction(PredictionMarketAMMAtlas(config.prediction), pairs);
        vm.stopBroadcast();
    }

    function _seedConfig() internal view virtual returns (SeedConfig memory config) {
        config.key = vm.envUint("PRIVATE_KEY");
        bytes32 target = keccak256(bytes(vm.envOr("ATLAS_SEED_TARGET", string("all"))));
        bool all = target == keccak256("all");
        require(
            all || target == keccak256("perp") || target == keccak256("option") || target == keccak256("prediction"),
            "Invalid Atlas seed target"
        );
        if (all || target == keccak256("perp")) {
            config.perp = vm.envAddress("PERPDEX_ATLAS_ADDRESS");
            require(config.perp != address(0), "PERPDEX_ATLAS_ADDRESS is zero");
        }
        if (all || target == keccak256("option")) {
            config.option = vm.envAddress("OPTION_AMM_ATLAS_ADDRESS");
            require(config.option != address(0), "OPTION_AMM_ATLAS_ADDRESS is zero");
        }
        if (all || target == keccak256("prediction")) {
            config.prediction = vm.envAddress("PREDICTION_MARKET_AMM_ATLAS_ADDRESS");
            require(config.prediction != address(0), "PREDICTION_MARKET_AMM_ATLAS_ADDRESS is zero");
        }
    }
}
