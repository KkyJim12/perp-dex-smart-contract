// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import "./InitialPairConfig.sol";

/// @notice Configure an already-deployed PerpDEX owned by PRIVATE_KEY.
contract ConfigurePerpDexPairs is Script, InitialPairConfig {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        PerpDEX dex = PerpDEX(
            payable(vm.envAddress("PERPDEX_ADDRESS"))
        );

        vm.startBroadcast(privateKey);
        _configurePerpDex(dex);
        vm.stopBroadcast();
    }
}

/// @notice Configure an already-deployed OneClickPerpDex owned by PRIVATE_KEY.
contract ConfigureOneClickPairs is Script, InitialPairConfig {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        OneClickPerpDex dex = OneClickPerpDex(
            payable(vm.envAddress("ONECLICK_PERPDEX_ADDRESS"))
        );

        vm.startBroadcast(privateKey);
        _configureOneClickPerpDex(dex);
        vm.stopBroadcast();
    }
}
