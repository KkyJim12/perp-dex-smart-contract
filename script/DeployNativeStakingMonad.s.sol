// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import "../src/NativeStaking.sol";

contract DeployNativeStakingMonad is Script {
    function run() external returns (address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("=== Deploying NativeStaking on Monad Mainnet ===");
        console.log("Chain ID: 143");

        vm.startBroadcast(deployerPrivateKey);

        NativeStaking staking = new NativeStaking();
        console.log("NativeStaking deployed at:", address(staking));

        // Authorize backend
        address backend = vm.envAddress("BACKEND_ADDRESS");
        if (backend != address(0)) {
            staking.authorizeBackend(backend, true);
            console.log("Backend authorized:", backend);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("NativeStaking:", address(staking));
        console.log("");
        console.log("Update .env.monad with:");
        console.log("NATIVE_STAKING_ADDRESS=", address(staking));

        return address(staking);
    }
}
