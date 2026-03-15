// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import "../src/OneClickPerpDex.sol";
import "../src/ocUSDC.sol";
import "../src/MockUSDC.sol";

contract DeployKubchainTestnet is Script {
    function run() external returns (address, address, address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        bool deployMockUSDC = vm.envBool("DEPLOY_MOCK_USDC");
        
        address usdcAddress;

        console.log("=== Kubchain Testnet Deployment ===");
        console.log("Chain ID: 25925");
        console.log("RPC URL:", vm.envString("RPC_URL"));
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy or use existing USDC
        if (deployMockUSDC) {
            console.log("Deploying Mock USDC...");
            MockUSDC mockUSDC = new MockUSDC();
            usdcAddress = address(mockUSDC);
            console.log("Mock USDC deployed at:");
            console.log(usdcAddress);
        } else {
            usdcAddress = vm.envAddress("USDC_ADDRESS");
            console.log("Using existing USDC at:");
            console.log(usdcAddress);
        }

        console.log("");

        // 2. Deploy ocUSDC token
        console.log("Deploying ocUSDC LP Token...");
        ocUSDC lpToken = new ocUSDC();
        console.log("ocUSDC deployed at:");
        console.log(address(lpToken));

        console.log("");

        // 3. Deploy OneClickPerpDex
        console.log("Deploying OneClickPerpDex...");
        OneClickPerpDex oneClick = new OneClickPerpDex(
            usdcAddress,
            address(lpToken)
        );
        console.log("OneClickPerpDex deployed at:");
        console.log(address(oneClick));

        console.log("");

        // 4. Set OneClickPerpDex address in ocUSDC (allows minting/burning)
        console.log("Configuring ocUSDC with OneClickPerpDex address...");
        lpToken.setOneClickPerpDex(address(oneClick));
        console.log("Configuration complete!");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("USDC Address:", usdcAddress);
        console.log("ocUSDC Token:", address(lpToken));
        console.log("OneClickPerpDex:", address(oneClick));
        
        console.log("");
        console.log("=== Update .env.kubchain ===");
        console.log("USDC_ADDRESS=", usdcAddress);
        console.log("OCUSDC_ADDRESS=", address(lpToken));
        console.log("ONECLICK_PERPDEX_ADDRESS=", address(oneClick));
        
        console.log("");
        console.log("=== Next Steps ===");
        console.log("1. Update .env.kubchain with the addresses above");
        console.log("");
        console.log("2. Authorize backend address:");
        console.log("   cast send", address(oneClick));
        console.log('   "authorizeBackend(address,bool)"');
        console.log("   $BACKEND_ADDRESS true");
        console.log("   --rpc-url $RPC_URL --private-key $PRIVATE_KEY --legacy");
        console.log("");
        console.log("3. Add initial liquidity (if needed):");
        console.log("   cast send", address(oneClick));
        console.log('   "addLiquidity(uint256)" <AMOUNT>');
        console.log("   --rpc-url $RPC_URL --private-key $PRIVATE_KEY --legacy");

        return (usdcAddress, address(lpToken), address(oneClick));
    }
}
