// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import "./InitialPairConfig.sol";

/// @notice Seed both deployed DEX contracts using the canonical initial pairs.
contract ConfigureInitialPairs is Script, InitialPairConfig {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        PerpDex dex = PerpDex(payable(vm.envAddress("PERPDEX_ADDRESS")));
        OneClickPerpDex oneClick = OneClickPerpDex(payable(vm.envAddress("ONECLICK_PERPDEX_ADDRESS")));

        require(address(dex).code.length > 0, "No PerpDex at target address");
        require(address(oneClick).code.length > 0, "No OneClick at target address");
        require(dex.owner() == vm.addr(privateKey), "Signer is not PerpDex owner");
        require(oneClick.owner() == vm.addr(privateKey), "Signer is not OneClick owner");

        vm.startBroadcast(privateKey);
        _configurePerpDex(dex);
        _configureOneClickPerpDex(oneClick);
        vm.stopBroadcast();
    }
}

/// @notice Configure an already-deployed PerpDex owned by PRIVATE_KEY.
contract ConfigurePerpDexPairs is Script, InitialPairConfig {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        PerpDex dex = PerpDex(payable(vm.envAddress("PERPDEX_ADDRESS")));

        require(address(dex).code.length > 0, "No PerpDex at target address");
        require(dex.owner() == vm.addr(privateKey), "Signer is not PerpDex owner");

        vm.startBroadcast(privateKey);
        _configurePerpDex(dex);
        vm.stopBroadcast();
    }
}

/// @notice Configure an already-deployed OneClickPerpDex owned by PRIVATE_KEY.
contract ConfigureOneClickPairs is Script, InitialPairConfig {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        OneClickPerpDex dex = OneClickPerpDex(payable(vm.envAddress("ONECLICK_PERPDEX_ADDRESS")));

        require(address(dex).code.length > 0, "No OneClick at target address");
        require(dex.owner() == vm.addr(privateKey), "Signer is not OneClick owner");

        vm.startBroadcast(privateKey);
        _configureOneClickPerpDex(dex);
        vm.stopBroadcast();
    }
}
