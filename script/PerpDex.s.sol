// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PerpDEX} from "../src/PerpDex.sol";

contract PerpDexScript is Script {
    PerpDEX public PerpDex;

    function setUp() public {}

    function run() public {
        address pythAddress = 0xA2aa501b19aff244D90cc15a4Cf739D2725B5729; // Sepolia Pyth
        address usdtAddress = 0xe673aCedccEb6D19a4353f6fD10EceaE5453ae6f; // Use deployed USDT or test token

        vm.startBroadcast();

        PerpDEX deployed = new PerpDEX(usdtAddress, pythAddress);

        console.log("Deployed at:", address(deployed));

        vm.stopBroadcast();
    }
}
