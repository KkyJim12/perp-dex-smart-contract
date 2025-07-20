// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PerpDEX} from "../src/PerpDex.sol";

contract PerpDexScript is Script {
    PerpDEX public PerpDex;

    function setUp() public {}

    function run() public {
        address usdtAddress = vm.envAddress("USDT_ADDRESS");
        address pythAddress = vm.envAddress("PYTH_ADDRESS");

        vm.startBroadcast();

        PerpDEX deployed = new PerpDEX(usdtAddress, pythAddress);

        console.log("Deployed at:", address(deployed));

        vm.stopBroadcast();
    }
}
