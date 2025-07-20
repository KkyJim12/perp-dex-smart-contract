// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/MockUSDT.sol";

contract DeployMockUSDT is Script {
    function run() external {
        vm.startBroadcast();

        MockUSDT usdt = new MockUSDT();

        console.log("MockUSDT deployed at:", address(usdt));

        vm.stopBroadcast();
    }
}
