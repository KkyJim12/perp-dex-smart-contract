// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {OptionAMMAtlas} from "../src/OptionAMMAtlas.sol";
import {opUSDC} from "../src/opUSDC.sol";

/// @notice Deploy an independent Atlas option vault with fresh, one-time-wired LP shares.
contract DeployOptionAMMAtlas is Script {
    function run() external returns (address atlasOpUSDCAddress, address optionAMMAtlasAddress) {
        (uint256 key, address usdc, address signer) = _deploymentConfig();
        vm.startBroadcast(key);
        opUSDC shares = new opUSDC();
        OptionAMMAtlas amm = new OptionAMMAtlas(usdc, signer, address(shares));
        shares.setOptionAMM(address(amm));
        vm.stopBroadcast();
        return (address(shares), address(amm));
    }

    /// @dev Test fixtures override configuration without mutating process-wide environment variables.
    function _deploymentConfig() internal view virtual returns (uint256 key, address usdc, address signer) {
        key = vm.envUint("PRIVATE_KEY");
        usdc = vm.envAddress("USDC_ADDRESS");
        signer = vm.envOr("ATLAS_SIGNER", address(0x59eD4701224fD9e2a85Ef2946c2ab828C1dDC600));
    }
}
