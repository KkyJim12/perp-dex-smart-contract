// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/User.sol";

contract DeployUser is Script {
    function run() external {
        vm.startBroadcast();

        User user = new User();

        console.log("User deployed at:", address(user));

        vm.stopBroadcast();
    }
}
