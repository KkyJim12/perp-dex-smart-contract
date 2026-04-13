// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import "../src/NativeStaking.sol";

contract DeployKubchainMainnet is Script {
    function run() external returns (address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address backend = vm.envAddress("BACKEND_ADDRESS");

        console.log("=== Kubchain Mainnet - NativeStaking ===");
        console.log("Chain ID: 96");

        vm.startBroadcast(deployerPrivateKey);

        NativeStaking staking = new NativeStaking();
        console.log("NativeStaking:", address(staking));

        if (backend != address(0)) {
            staking.authorizeBackend(backend, true);
            console.log("Backend authorized:", backend);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("NATIVE_STAKING_ADDRESS=", address(staking));

        return address(staking);
    }
}
