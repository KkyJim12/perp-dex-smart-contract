// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PerpDexAtlas} from "../src/PerpDexAtlas.sol";
import {OptionAMMAtlas} from "../src/OptionAMMAtlas.sol";
import {PredictionMarketAMMAtlas} from "../src/PredictionMarketAMMAtlas.sol";
import {ppUSDC} from "../src/ppUSDC.sol";
import {opUSDC} from "../src/opUSDC.sol";

/// @notice Deploy all three Atlas vaults and fresh LP tokens using existing USDC.
contract DeployAtlas is Script {
    struct Config {
        uint256 key;
        address usdc;
        address signer;
        uint256 maxPriceAge;
        uint256 predictionFeeBps;
    }

    struct Deployment {
        address perpShares;
        address perp;
        address optionShares;
        address option;
        address predictionShares;
        address prediction;
    }

    function run() external returns (Deployment memory deployed) {
        Config memory config = _deploymentConfig();
        // Validate shared configuration before preparing any deployment transactions.
        require(config.usdc.code.length > 0, "Invalid USDC contract");
        require(IERC20Metadata(config.usdc).decimals() == 6, "USDC must have 6 decimals");
        require(config.signer != address(0), "Invalid Atlas signer");
        require(config.maxPriceAge > 0 && config.maxPriceAge <= 5, "Invalid max price age");
        require(config.predictionFeeBps <= 500, "Prediction fee exceeds 5%");

        vm.startBroadcast(config.key);
        ppUSDC perpShares = new ppUSDC();
        PerpDexAtlas perp = new PerpDexAtlas(config.usdc, address(perpShares), config.signer, config.maxPriceAge);
        perpShares.setMinter(address(perp), true);

        opUSDC optionShares = new opUSDC();
        OptionAMMAtlas option = new OptionAMMAtlas(config.usdc, config.signer, address(optionShares));
        optionShares.setOptionAMM(address(option));

        PredictionMarketAMMAtlas prediction =
            new PredictionMarketAMMAtlas(config.usdc, config.signer, config.predictionFeeBps);
        vm.stopBroadcast();

        deployed = Deployment({
            perpShares: address(perpShares),
            perp: address(perp),
            optionShares: address(optionShares),
            option: address(option),
            predictionShares: address(prediction.shareToken()),
            prediction: address(prediction)
        });

        console2.log("Atlas addresses (save only after successful broadcast confirmation):");
        console2.log("ATLAS_PPUSDC_ADDRESS=%s", deployed.perpShares);
        console2.log("PERPDEX_ATLAS_ADDRESS=%s", deployed.perp);
        console2.log("ATLAS_OPUSDC_ADDRESS=%s", deployed.optionShares);
        console2.log("OPTION_AMM_ATLAS_ADDRESS=%s", deployed.option);
        console2.log("ATLAS_PMUSDC_ADDRESS=%s", deployed.predictionShares);
        console2.log("PREDICTION_MARKET_AMM_ATLAS_ADDRESS=%s", deployed.prediction);
    }

    /// @dev Fixtures override configuration without changing process-wide environment variables.
    function _deploymentConfig() internal view virtual returns (Config memory config) {
        config.key = vm.envUint("PRIVATE_KEY");
        config.usdc = vm.envAddress("USDC_ADDRESS");
        config.signer = vm.envOr("ATLAS_SIGNER", address(0x59eD4701224fD9e2a85Ef2946c2ab828C1dDC600));
        config.maxPriceAge = vm.envOr("ATLAS_MAX_PRICE_AGE", uint256(5));
        config.predictionFeeBps = vm.envOr("PREDICTION_FEE_BPS", uint256(300));
    }
}
