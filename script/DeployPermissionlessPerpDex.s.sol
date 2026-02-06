// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import "../src/PermissionlessPerpDex.sol";
import "../src/MockUSDC.sol";
import "../src/ppUSDC.sol";

contract DeployPermissionlessPerpDex is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying PermissionlessPerpDex contracts...");
        console.log("Deployer:", deployer);
        console.log("Deployer balance:", deployer.balance);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Get USDC address from environment or deploy MockUSDC
        address usdcAddress;
        
        // Try to get existing USDC address from environment
        try vm.envAddress("USDC_ADDRESS") returns (address existingUSDC) {
            usdcAddress = existingUSDC;
            console.log("Using existing USDC at:", usdcAddress);
        } catch {
            // Deploy MockUSDC if no existing USDC address
            console.log("Deploying MockUSDC...");
            MockUSDC mockUSDC = new MockUSDC();
            usdcAddress = address(mockUSDC);
            console.log("MockUSDC deployed at:", usdcAddress);
        }
        
        // Get ppUSDC address from environment or deploy new one
        address ppUSDCAddress;
        
        try vm.envAddress("PPUSDC_ADDRESS") returns (address existingPPUSDC) {
            ppUSDCAddress = existingPPUSDC;
            console.log("Using existing ppUSDC at:", ppUSDCAddress);
        } catch {
            // Deploy ppUSDC if no existing address
            console.log("Deploying ppUSDC...");
            ppUSDC ppusdc = new ppUSDC();
            ppUSDCAddress = address(ppusdc);
            console.log("ppUSDC deployed at:", ppUSDCAddress);
        }
        
        // Deploy PermissionlessPerpDex
        console.log("Deploying PermissionlessPerpDex...");
        PermissionlessPerpDex permissionlessPerpDex = new PermissionlessPerpDex(usdcAddress, ppUSDCAddress);
        console.log("PermissionlessPerpDex deployed at:", address(permissionlessPerpDex));
        
        // If we deployed ppUSDC, set PermissionlessPerpDex as minter
        try vm.envAddress("PPUSDC_ADDRESS") returns (address) {
            console.log("Using existing ppUSDC - make sure PermissionlessPerpDex is authorized as minter");
        } catch {
            console.log("Setting PermissionlessPerpDex as ppUSDC minter...");
            ppUSDC ppusdc = ppUSDC(ppUSDCAddress);
            ppusdc.setMinter(address(permissionlessPerpDex), true);
            console.log("PermissionlessPerpDex authorized as ppUSDC minter");
        }
        
        vm.stopBroadcast();
        
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("USDC Address:", usdcAddress);
        console.log("ppUSDC Address:", ppUSDCAddress);
        console.log("PermissionlessPerpDex Address:", address(permissionlessPerpDex));
        console.log("\n=== NEXT STEPS ===");
        console.log("1. Authorize your backend address using: authorizeBackend(backendAddress, true)");
        console.log("2. LPs can deposit USDC using: depositLP(amount)");
        console.log("3. Traders can deposit USDC using: deposit(amount)");
        console.log("4. Backend can open positions using: openPosition(user, pair, isLong, margin, leverage, entryPrice)");
        console.log("5. Backend can close positions using: closePosition(positionId, exitPrice, reason)");
    }
}