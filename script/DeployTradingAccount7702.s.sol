// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "lib/forge-std/src/Script.sol";
import {TradingAccount7702} from "../src/TradingAccount7702.sol";

/// @notice Deploy once per chain; each wallet separately authorizes delegation.
contract DeployTradingAccount7702 is Script {
    function run() external returns (address implementation) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);
        implementation = address(new TradingAccount7702());
        vm.stopBroadcast();
        console.log("TradingAccount7702 implementation:", implementation);
        console.log("Use only on a chain that supports EIP-7702.");
    }
}
