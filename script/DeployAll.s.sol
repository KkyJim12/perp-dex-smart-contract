// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import "../src/PerpDex.sol";
import "../src/ppUSDC.sol";
import "../src/MockUSDC.sol";
import "../src/OneClickPerpDex.sol";
import "../src/ocUSDC.sol";
import "./InitialPairConfig.sol";

contract DeployAll is Script, InitialPairConfig {
    function run() external returns (
        address usdcAddress,
        address ppUSDCAddress,
        address perpDexAddress,
        address ocUSDCAddress,
        address oneClickPerpDexAddress
    ) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address pythAddress = vm.envAddress("PYTH_ADDRESS");
        
        // Check if we should deploy MockUSDC or use existing USDC
        bool deployMockUSDC = vm.envOr("DEPLOY_MOCK_USDC", true);

        console.log("===================================");
        console.log("Complete PerpDex Deployment");
        console.log("===================================");
        console.log("Network: connected RPC");
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ================================================================
        // STEP 1: Deploy USDC (MockUSDC or use existing)
        // ================================================================
        console.log("=== Step 1: Deploy/Use USDC ===");
        if (deployMockUSDC) {
            MockUSDC mockUSDC = new MockUSDC();
            usdcAddress = address(mockUSDC);
            console.log("MockUSDC deployed at:");
            console.log(usdcAddress);
        } else {
            usdcAddress = vm.envAddress("USDC_ADDRESS");
            console.log("Using existing USDC at:");
            console.log(usdcAddress);
        }
        console.log("");

        // ================================================================
        // STEP 2: Deploy ppUSDC (LP token for main PerpDex)
        // ================================================================
        console.log("=== Step 2: Deploy ppUSDC (Main PerpDex LP Token) ===");
        ppUSDC lpToken = new ppUSDC();
        ppUSDCAddress = address(lpToken);
        console.log("ppUSDC deployed at:");
        console.log(ppUSDCAddress);
        console.log("");

        // ================================================================
        // STEP 3: Deploy Main PerpDex
        // ================================================================
        console.log("=== Step 3: Deploy Main PerpDex ===");
        PerpDEX perpDex = new PerpDEX(usdcAddress, pythAddress, ppUSDCAddress);
        perpDexAddress = address(perpDex);
        _configurePerpDex(perpDex);
        console.log("Main PerpDex deployed at:");
        console.log(perpDexAddress);
        console.log("");

        // ================================================================
        // STEP 4: Configure ppUSDC with Main PerpDex
        // ================================================================
        console.log("=== Step 4: Configure ppUSDC ===");
        lpToken.setMinter(perpDexAddress, true);
        console.log("ppUSDC configured with Main PerpDex address");
        console.log("");

        // ================================================================
        // STEP 5: Deploy ocUSDC (LP token for OneClick PerpDex)
        // ================================================================
        console.log("=== Step 5: Deploy ocUSDC (OneClick PerpDex LP Token) ===");
        ocUSDC ocLpToken = new ocUSDC();
        ocUSDCAddress = address(ocLpToken);
        console.log("ocUSDC deployed at:");
        console.log(ocUSDCAddress);
        console.log("");

        // ================================================================
        // STEP 6: Deploy OneClick PerpDex
        // ================================================================
        console.log("=== Step 6: Deploy OneClick PerpDex ===");
        OneClickPerpDex oneClick = new OneClickPerpDex(usdcAddress, ocUSDCAddress);
        oneClickPerpDexAddress = address(oneClick);
        _configureOneClickPerpDex(oneClick);
        console.log("OneClick PerpDex deployed at:");
        console.log(oneClickPerpDexAddress);
        console.log("");

        // ================================================================
        // STEP 7: Configure ocUSDC with OneClick PerpDex
        // ================================================================
        console.log("=== Step 7: Configure ocUSDC ===");
        ocLpToken.setOneClickPerpDex(oneClickPerpDexAddress);
        console.log("ocUSDC configured with OneClick PerpDex address");
        console.log("");

        vm.stopBroadcast();

        // ================================================================
        // DEPLOYMENT SUMMARY
        // ================================================================
        console.log("===================================");
        console.log("Deployment Summary");
        console.log("===================================");
        console.log("");
        
        console.log("--- Shared ---");
        if (deployMockUSDC) {
            console.log("MockUSDC:");
        } else {
            console.log("USDC:");
        }
        console.log(usdcAddress);
        console.log("");
        
        console.log("--- Main PerpDex System ---");
        console.log("ppUSDC Token:");
        console.log(ppUSDCAddress);
        console.log("Main PerpDex:");
        console.log(perpDexAddress);
        console.log("Pyth Oracle:");
        console.log(pythAddress);
        console.log("");
        
        console.log("--- OneClick PerpDex System ---");
        console.log("ocUSDC Token:");
        console.log(ocUSDCAddress);
        console.log("OneClick PerpDex:");
        console.log(oneClickPerpDexAddress);
        console.log("");

        // ================================================================
        // NEXT STEPS
        // ================================================================
        console.log("===================================");
        console.log("Next Steps");
        console.log("===================================");
        console.log("");
        
        console.log("1. Authorize backend for OneClick PerpDex:");
        console.log("cast send");
        console.log(oneClickPerpDexAddress);
        console.log('"authorizeBackend(address,bool)" <BACKEND_ADDRESS> true');
        console.log("--rpc-url $RPC_URL --private-key $PRIVATE_KEY");
        console.log("");
        
        if (deployMockUSDC) {
            console.log("2. Mint test USDC (optional):");
            console.log("cast send");
            console.log(usdcAddress);
            console.log('"mint(address,uint256)" <YOUR_ADDRESS> 1000000000');
            console.log("--rpc-url $RPC_URL --private-key $PRIVATE_KEY");
            console.log("");
        }

        // ================================================================
        // VERIFICATION COMMANDS
        // ================================================================
        console.log("===================================");
        console.log("Verification Commands");
        console.log("===================================");
        console.log("");
        
        if (deployMockUSDC) {
            console.log("--- MockUSDC ---");
            console.log("forge verify-contract");
            console.log(usdcAddress);
            console.log("src/MockUSDC.sol:MockUSDC --watch");
            console.log("");
        }
        
        console.log("--- ppUSDC ---");
        console.log("forge verify-contract");
        console.log(ppUSDCAddress);
        console.log("src/ppUSDC.sol:ppUSDC --watch");
        console.log("");
        
        console.log("--- Main PerpDex ---");
        console.log("forge verify-contract");
        console.log(perpDexAddress);
        console.log("src/PerpDex.sol:PerpDEX");
        console.log("--constructor-args $(cast abi-encode 'constructor(address,address,address)'");
        console.log(usdcAddress);
        console.log(pythAddress);
        console.log(ppUSDCAddress);
        console.log(")");
        console.log("--watch");
        console.log("");
        
        console.log("--- ocUSDC ---");
        console.log("forge verify-contract");
        console.log(ocUSDCAddress);
        console.log("src/ocUSDC.sol:ocUSDC --watch");
        console.log("");
        
        console.log("--- OneClick PerpDex ---");
        console.log("forge verify-contract");
        console.log(oneClickPerpDexAddress);
        console.log("src/OneClickPerpDex.sol:OneClickPerpDex");
        console.log("--constructor-args $(cast abi-encode 'constructor(address,address)'");
        console.log(usdcAddress);
        console.log(ocUSDCAddress);
        console.log(")");
        console.log("--watch");
        console.log("");

        // ================================================================
        // SAVE ADDRESSES TO ENV
        // ================================================================
        console.log("===================================");
        console.log("Save These Addresses to .env");
        console.log("===================================");
        console.log("");
        console.log("USDC_ADDRESS=", usdcAddress);
        console.log("PPUSDC_ADDRESS=", ppUSDCAddress);
        console.log("PERPDEX_ADDRESS=", perpDexAddress);
        console.log("OCUSDC_ADDRESS=", ocUSDCAddress);
        console.log("ONECLICK_PERPDEX_ADDRESS=", oneClickPerpDexAddress);
        console.log("");

        return (usdcAddress, ppUSDCAddress, perpDexAddress, ocUSDCAddress, oneClickPerpDexAddress);
    }
}
