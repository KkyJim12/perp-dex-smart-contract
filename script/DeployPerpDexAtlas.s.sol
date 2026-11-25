// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {PerpDexAtlas} from "../src/PerpDexAtlas.sol";
import {ppUSDC} from "../src/ppUSDC.sol";

/// @notice Deploy an isolated Atlas vault and fresh ppUSDC token using existing USDC.
contract DeployPerpDexAtlas is Script {
    function run() external returns (address atlasPpUSDCAddress, address perpDexAtlasAddress) {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address usdc = vm.envAddress("USDC_ADDRESS");
        // Production key published by Atlas; override after an official rotation.
        address signer = vm.envOr("ATLAS_SIGNER", address(0x59eD4701224fD9e2a85Ef2946c2ab828C1dDC600));
        uint256 maxAge = vm.envOr("ATLAS_MAX_PRICE_AGE", uint256(60));

        vm.startBroadcast(key);
        ppUSDC shares = new ppUSDC();
        PerpDexAtlas dex = new PerpDexAtlas(usdc, address(shares), signer, maxAge);
        shares.setMinter(address(dex), true);
        vm.stopBroadcast();

        return (address(shares), address(dex));
    }
}
