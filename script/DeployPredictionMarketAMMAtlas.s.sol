// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {PredictionMarketAMMAtlas} from "../src/PredictionMarketAMMAtlas.sol";

/// @notice The isolated prediction vault creates and owns its fresh pmUSDC share token.
contract DeployPredictionMarketAMMAtlas is Script {
    function run() external returns (address atlasPmUSDCAddress, address predictionMarketAMMAtlasAddress) {
        (uint256 key, address usdc, address signer, uint256 fee) = _deploymentConfig();
        vm.startBroadcast(key);
        PredictionMarketAMMAtlas amm = new PredictionMarketAMMAtlas(usdc, signer, fee);
        vm.stopBroadcast();
        return (address(amm.shareToken()), address(amm));
    }

    /// @dev Test fixtures override configuration without mutating process-wide environment variables.
    function _deploymentConfig()
        internal
        view
        virtual
        returns (uint256 key, address usdc, address signer, uint256 fee)
    {
        key = vm.envUint("PRIVATE_KEY");
        usdc = vm.envAddress("USDC_ADDRESS");
        signer = vm.envOr("ATLAS_SIGNER", address(0x59eD4701224fD9e2a85Ef2946c2ab828C1dDC600));
        fee = vm.envOr("PREDICTION_FEE_BPS", uint256(300));
    }
}
