// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import "../src/NativeStaking.sol";

contract DeployNativeStaking is Script {
    function run() external returns (address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("=== Deploying NativeStaking ===");

        vm.startBroadcast(deployerPrivateKey);

        NativeStaking staking = new NativeStaking();
        console.log("NativeStaking deployed at:", address(staking));

        // Authorize backend if set
        try vm.envAddress("BACKEND_ADDRESS") returns (address backend) {
            if (backend != address(0)) {
                staking.authorizeBackend(backend, true);
                console.log("Backend authorized:", backend);
            }
        } catch {}

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("NativeStaking:", address(staking));
        console.log("");
        console.log("Deploy command used:");
        console.log("forge script script/DeployNativeStaking.s.sol:DeployNativeStaking --rpc-url $RPC_URL --private-key $PRIVATE_KEY --legacy --broadcast -vvvv");

        return address(staking);
    }
}
